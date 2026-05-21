import Foundation
import LoggerRemote
import Loggers
import Testing

@testable import LoggerAxiom

/// Boundary coverage for ``AxiomLoggingService``: invalid periodic
/// intervals (non-positive, non-finite, sub-nanosecond) and
/// deallocation while a periodic loop is running.
@Suite("AxiomLoggingService boundary cases")
struct AxiomLoggingServiceBoundaryTests {
    // These windows intentionally exceed `shortInterval` so scheduler jitter
    // does not turn periodic-loop assertions into timing flakes.
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

    @Test(
        "`.periodic(seconds: 0)` does not start a periodic loop and surfaces `invalidFlushInterval`",
        .tags(.axm44)
    )
    func invalidPeriodicIntervalDoesNotStartLoop() async throws {
        let sink = RecordingAxiomLogSink()
        let diagnostics = LoggingServiceDiagnosticCollector()
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .periodic(seconds: 0),
            onDiagnostic: diagnostics.callback
        )

        service.start()
        try await Task.sleep(nanoseconds: Self.waitForTicks)
        let countAfterWait = sink.flushCallCount
        await service.stop()

        #expect(countAfterWait == 0)
        #expect(diagnostics.diagnostics == [.invalidFlushInterval(seconds: 0)])
        #expect(sink.flushCallCount == 1)
    }

    @Test(
        "`.periodic(seconds: .nan)` does not start a periodic loop and surfaces `invalidFlushInterval`",
        .tags(.axm44)
    )
    func nanPeriodicIntervalDoesNotStartLoop() async throws {
        let sink = RecordingAxiomLogSink()
        let diagnostics = LoggingServiceDiagnosticCollector()
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .periodic(seconds: .nan),
            onDiagnostic: diagnostics.callback
        )

        service.start()
        try await Task.sleep(nanoseconds: Self.waitForTicks)
        await service.stop()

        #expect(sink.flushCallCount == 1)
        #expect(diagnostics.diagnostics == [.invalidFlushInterval(seconds: .nan)])
    }

    @Test(
        "Sub-nanosecond periodic interval truncating to zero is rejected as `invalidFlushInterval`",
        .tags(.axm44)
    )
    func subNanosecondPeriodicIntervalIsRejected() async throws {
        let sink = RecordingAxiomLogSink()
        let diagnostics = LoggingServiceDiagnosticCollector()
        let logger = Self.makeLogger(sink: sink)
        let service = AxiomLoggingService(
            logger: logger,
            flushPolicy: .periodic(seconds: 1e-10),
            onDiagnostic: diagnostics.callback
        )

        service.start()
        try await Task.sleep(nanoseconds: Self.waitForTicks)
        let countAfterWait = sink.flushCallCount
        await service.stop()

        #expect(countAfterWait == 0)
        #expect(diagnostics.diagnostics == [.invalidFlushInterval(seconds: 1e-10)])
        #expect(sink.flushCallCount == 1)
    }

    @Test(
        "Deallocating the service without `stop()` cancels the periodic loop",
        .tags(.axm45)
    )
    func deinitCancelsPeriodicLoop() async throws {
        let sink = RecordingAxiomLogSink()
        let logger = Self.makeLogger(sink: sink)

        // Construct, start, and drop the service inside a child
        // scope so its only strong reference goes away before the
        // post-drop quiet window. The periodic loop captures only
        // `logger` and `onDiagnostic`, so the task does not retain
        // the service; without `deinit { ... cancel() }` the loop
        // would keep flushing after the service is gone.
        do {
            let service = AxiomLoggingService(
                logger: logger,
                flushPolicy: .periodic(seconds: Self.shortInterval)
            )
            service.start()
            try await Task.sleep(nanoseconds: Self.waitForTicks)
            _ = service
        }

        let countAfterDrop = sink.flushCallCount
        try await Task.sleep(nanoseconds: Self.postStopQuietWindow)
        #expect(sink.flushCallCount == countAfterDrop)
        #expect(countAfterDrop >= 2)
    }
}
