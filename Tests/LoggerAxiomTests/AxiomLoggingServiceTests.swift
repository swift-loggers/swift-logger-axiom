import Foundation
import LoggerRemote
import Loggers
import Testing

@testable import LoggerAxiom

/// Coverage for ``AxiomLoggingService`` lifecycle, periodic
/// cadence, explicit ``AxiomLoggingService/flush()`` forwarding, and
/// diagnostic routing. The suite drives the service over an
/// ``AxiomLogger`` constructed with the closure-seam initializer so
/// every flush attempt is observable through the test sink.
@Suite("AxiomLoggingService")
struct AxiomLoggingServiceTests {
    private static let shortInterval: TimeInterval = 0.005
    private static let waitForTicks: UInt64 = 80_000_000
    private static let postStopQuietWindow: UInt64 = 40_000_000

    private static func makeLogger(
        sink: RecordingAxiomLogSink
    ) -> AxiomLogger {
        AxiomLogger(
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )
    }

    // MARK: Lifecycle

    @Test(
        "`.manual` start does not drive a periodic flush",
        .tags(.axm36)
    )
    func manualPolicyDoesNotFlushPeriodically() async throws {
        let sink = RecordingAxiomLogSink()
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .manual
        )

        service.start()
        try await Task.sleep(nanoseconds: Self.waitForTicks)
        let countBeforeStop = sink.flushCallCount

        await service.stop()

        #expect(countBeforeStop == 0)
        // `stop()` always performs one final flush.
        #expect(sink.flushCallCount == 1)
    }

    @Test(
        "`start()` is idempotent: repeated calls launch a single periodic loop",
        .tags(.axm35)
    )
    func startIsIdempotent() async throws {
        let sink = RecordingAxiomLogSink()
        let detector = ConcurrentFlushDetector()
        sink.setEngineFlushObserver { detector.recordEvent() }
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .periodic(seconds: Self.shortInterval)
        )

        service.start()
        service.start()
        service.start()

        try await Task.sleep(nanoseconds: Self.waitForTicks)
        await service.stop()

        #expect(detector.observedMaxConcurrent <= 1)
    }

    @Test(
        "`.periodic(seconds:)` drives at least one flush per interval window",
        .tags(.axm37)
    )
    func periodicPolicyDrivesFlushes() async throws {
        let sink = RecordingAxiomLogSink()
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .periodic(seconds: Self.shortInterval)
        )

        service.start()
        try await Task.sleep(nanoseconds: Self.waitForTicks)
        let countWhileRunning = sink.flushCallCount
        await service.stop()

        // At a 5 ms cadence the loop should have ticked several times
        // inside the 80 ms window; the lower bound is conservative
        // against scheduler jitter.
        #expect(countWhileRunning >= 2)
    }

    @Test(
        "Periodic flushes never overlap",
        .tags(.axm38)
    )
    func periodicFlushesAreSerial() async throws {
        let sink = RecordingAxiomLogSink()
        let detector = ConcurrentFlushDetector(flushHoldNanoseconds: 5_000_000)
        sink.setEngineFlushObserver { detector.recordEvent() }
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .periodic(seconds: 0.001)
        )

        service.start()
        try await Task.sleep(nanoseconds: Self.waitForTicks)
        await service.stop()

        #expect(detector.observedMaxConcurrent == 1)
    }

    // MARK: Explicit flush forwarding

    @Test(
        "`flush()` forwards the engine's `RemoteFlushSummary`",
        .tags(.axm39)
    )
    func flushForwardsSummary() async throws {
        let sink = RecordingAxiomLogSink()
        let summary = RemoteFlushSummary(
            attemptedBatches: 2,
            attemptedEntries: 5,
            succeededEntries: 5,
            terminalEntries: 0,
            retryableEntries: 0,
            acknowledgement: .removedDeliveredBytes
        )
        sink.setEngineFlushSummary(summary)
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .manual
        )

        let returned = try await service.flush()

        #expect(returned == summary)
        #expect(sink.flushCallCount == 1)
    }

    @Test(
        "`flush()` re-throws the engine's error",
        .tags(.axm39)
    )
    func flushRethrowsError() async throws {
        let sink = RecordingAxiomLogSink()
        sink.setEngineFlushError(AxiomFixtureError.scripted)
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .manual
        )

        await #expect(throws: AxiomFixtureError.scripted) {
            _ = try await service.flush()
        }
    }

    // MARK: Stop semantics

    @Test(
        "`stop()` cancels the periodic loop; no flush fires after it returns",
        .tags(.axm40)
    )
    func stopCancelsPeriodicLoop() async throws {
        let sink = RecordingAxiomLogSink()
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .periodic(seconds: Self.shortInterval)
        )

        service.start()
        try await Task.sleep(nanoseconds: Self.waitForTicks)
        await service.stop()
        let countAfterStop = sink.flushCallCount

        try await Task.sleep(nanoseconds: Self.postStopQuietWindow)
        #expect(sink.flushCallCount == countAfterStop)
    }

    @Test(
        "Concurrent `stop()` callers all wait for the same final flush",
        .tags(.axm40)
    )
    func concurrentStopWaitsForFinalFlush() async throws {
        let sink = RecordingAxiomLogSink()
        let firstFlushStarted = BlockingGate()
        let unblockFlush = BlockingGate()
        sink.installEngineFlushGate(unblockFlush)
        sink.setEngineFlushObserver { firstFlushStarted.open() }
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .manual
        )

        let completions = StopCompletionCounter()

        // First stop reaches the engine-flush gate and parks there.
        let firstStop = Task { @Sendable in
            await service.stop()
            completions.increment()
        }
        await firstFlushStarted.wait()

        // With the in-flight stop parked inside the final flush, the
        // second `stop()` must join the same stop work and not return
        // until the final flush completes.
        let secondStop = Task { @Sendable in
            await service.stop()
            completions.increment()
        }

        // Both stops should still be parked: the flush is gated.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(completions.value == 0)

        // Release the engine flush; both stops resolve.
        unblockFlush.open()
        await firstStop.value
        await secondStop.value

        #expect(completions.value == 2)
        // The final flush runs exactly once per service instance.
        #expect(sink.flushCallCount == 1)
    }

    @Test(
        "`stop()` performs exactly one final flush even under `.manual`",
        .tags(.axm40)
    )
    func stopPerformsFinalFlush() async throws {
        let sink = RecordingAxiomLogSink()
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .manual
        )

        #expect(sink.flushCallCount == 0)
        await service.stop()
        #expect(sink.flushCallCount == 1)

        // Subsequent stops are no-ops.
        await service.stop()
        #expect(sink.flushCallCount == 1)
    }

    // MARK: Diagnostics

    @Test(
        "Periodic flush failure surfaces `flushFailed(String)` and keeps the loop running",
        .tags(.axm41)
    )
    func periodicFailureSurfacesDiagnostic() async throws {
        let sink = RecordingAxiomLogSink()
        sink.setEngineFlushError(AxiomFixtureError.scripted)
        let diagnostics = LoggingServiceDiagnosticCollector()
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .periodic(seconds: Self.shortInterval),
            onDiagnostic: diagnostics.callback
        )

        service.start()
        try await Task.sleep(nanoseconds: Self.waitForTicks)
        let countWhileRunning = sink.flushCallCount
        await service.stop()

        let payloads = diagnostics.diagnostics
        #expect(payloads.count >= 2)
        for diagnostic in payloads {
            #expect(diagnostic == .flushFailed("scripted-fixture-error"))
        }
        // Loop kept calling flush despite every prior failure.
        #expect(countWhileRunning >= 2)
    }

    @Test(
        "Final flush failure inside `stop()` surfaces `flushFailed(String)` instead of throwing",
        .tags(.axm42)
    )
    func stopFinalFlushFailureSurfacesDiagnostic() async throws {
        let sink = RecordingAxiomLogSink()
        sink.setEngineFlushError(AxiomFixtureError.scripted)
        let diagnostics = LoggingServiceDiagnosticCollector()
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .manual,
            onDiagnostic: diagnostics.callback
        )

        await service.stop()

        #expect(diagnostics.diagnostics == [.flushFailed("scripted-fixture-error")])
    }

    // MARK: Race and platform independence

    @Test(
        "Concurrent `start()` and `stop()` never leaves a periodic task running past `stop()`",
        .tags(.axm40)
    )
    func startStopRaceDoesNotLeakPeriodicTask() async throws {
        for _ in 0 ..< 50 {
            let sink = RecordingAxiomLogSink()
            let logger = Self.makeLogger(sink: sink)
            let service = AxiomLoggingService(
                logger: logger,
                flushPolicy: .periodic(seconds: Self.shortInterval)
            )

            // Race start against stop. After `stop()` resolves, no
            // further periodic flush may fire even if `start()`
            // happened to install the task immediately before.
            async let starter: Void = service.start()
            async let stopper: Void = service.stop()
            _ = await (starter, stopper)

            let countAtStopReturn = sink.flushCallCount
            try await Task.sleep(nanoseconds: Self.postStopQuietWindow)
            #expect(sink.flushCallCount == countAtStopReturn)
        }
    }

    @Test(
        "Service, policy, and diagnostic sources declare no UIKit/AppKit/SwiftUI/WatchKit import",
        .tags(.axm43)
    )
    func serviceFamilyDeclaresNoPlatformImport() throws {
        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LoggerAxiom")
        let serviceFamily = [
            "AxiomLoggingService.swift",
            "AxiomFlushPolicy.swift",
            "AxiomLoggingServiceDiagnostic.swift"
        ]
        for fileName in serviceFamily {
            let sourceURL = sourcesRoot.appendingPathComponent(fileName)
            let contents = try String(contentsOf: sourceURL, encoding: .utf8)
            let imported = SwiftSourceImports.modules(in: contents)
            for forbidden in ["UIKit", "AppKit", "SwiftUI", "WatchKit"] {
                #expect(
                    !imported.contains(forbidden),
                    "\(fileName) must not import \(forbidden)"
                )
            }
        }
    }
}

// MARK: - Helpers

/// Counts how many concurrent ``AxiomLoggingService/stop()`` callers
/// have returned. Used to assert that all stop callers wait for the
/// in-flight stop to complete instead of returning early.
final class StopCompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Detects whether two flush callbacks ever ran concurrently and how
/// many calls completed in total. An optional `flushHoldNanoseconds`
/// delays each callback so a misconfigured concurrent loop would be
/// caught by the overlap.
final class ConcurrentFlushDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var maxConcurrent = 0
    private var total = 0
    private let holdNanoseconds: UInt64

    init(flushHoldNanoseconds: UInt64 = 0) {
        holdNanoseconds = flushHoldNanoseconds
    }

    func recordEvent() {
        lock.lock()
        inFlight += 1
        maxConcurrent = max(maxConcurrent, inFlight)
        total += 1
        lock.unlock()
        if holdNanoseconds > 0 {
            Thread.sleep(forTimeInterval: TimeInterval(holdNanoseconds) / 1_000_000_000)
        }
        lock.lock()
        inFlight -= 1
        lock.unlock()
    }

    var observedMaxConcurrent: Int {
        lock.lock()
        defer { lock.unlock() }
        return maxConcurrent
    }
}
