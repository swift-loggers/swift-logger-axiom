import Foundation
import LoggerRemote
import Loggers
import Testing

@testable import LoggerAxiom

/// Coverage for ``AxiomLogger`` admission, the internal worker, the
/// buffer-policy contract, the diagnostic callback, and the flush
/// barrier. The suite drives the logger through its `internal`
/// closure-seam initializer so the worker runs against scripted
/// `enqueue` / `engineFlush` behavior without standing up a
/// persistence-backed durable queue.
@Suite("AxiomLogger admission and worker")
struct AxiomLoggerTests {
    // MARK: Smoke

    @Test(
        "Default-configured logger admits an entry, encodes it, and runs engine flush",
        .tags(.axm16, .axm25)
    )
    func defaultConfigurationAdmitsAndFlushes() async throws {
        let sink = RecordingAxiomLogSink()
        sink.setEngineFlushSummary(RemoteFlushSummary(
            attemptedBatches: 1,
            attemptedEntries: 1,
            succeededEntries: 1,
            terminalEntries: 0,
            retryableEntries: 0,
            acknowledgement: .removedDeliveredBytes
        ))
        let logger = AxiomLogger(
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        logger.info(.test, "hello, axiom", attributes: [LogAttribute("k", "v")])
        let summary = try await logger.flush()

        #expect(sink.enqueuedCount == 1)
        #expect(sink.flushCallCount == 1)
        #expect(summary.succeededEntries == 1)
        let payload = try #require(sink.entries.first?.payload)
        let decoded = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(decoded["message"] as? String == "hello, axiom")
    }

    // MARK: Drop guards

    @Test(
        "LoggerLevel.disabled drop never evaluates message or attributes",
        .tags(.axm17)
    )
    func disabledLevelDoesNotEvaluateClosures() async throws {
        let sink = RecordingAxiomLogSink()
        let recorder = RecordingEvaluation()
        let diagnostics = DiagnosticCollector()
        let logger = AxiomLogger(
            onDiagnostic: diagnostics.callback,
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        logger.log(
            .disabled,
            .test,
            recorder.message("a"),
            attributes: recorder.attributes("a")
        )
        _ = try await logger.flush()

        #expect(recorder.callLog.isEmpty)
        #expect(sink.enqueuedCount == 0)
        #expect(diagnostics.diagnostics.isEmpty)
    }

    @Test(
        "Below-minimum-level drop never evaluates message or attributes",
        .tags(.axm18)
    )
    func belowMinimumDoesNotEvaluateClosures() async throws {
        let sink = RecordingAxiomLogSink()
        let recorder = RecordingEvaluation()
        let diagnostics = DiagnosticCollector()
        let logger = AxiomLogger(
            minimumLevel: .warning,
            onDiagnostic: diagnostics.callback,
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        logger.log(
            .info,
            .test,
            recorder.message("a"),
            attributes: recorder.attributes("a")
        )
        _ = try await logger.flush()

        #expect(recorder.callLog.isEmpty)
        #expect(sink.enqueuedCount == 0)
        #expect(diagnostics.diagnostics.isEmpty)
    }

    @Test(
        "Accepted entry evaluates message and attributes exactly once",
        .tags(.axm19)
    )
    func acceptedEntryEvaluatesClosuresExactlyOnce() async throws {
        let sink = RecordingAxiomLogSink()
        let recorder = RecordingEvaluation()
        let logger = AxiomLogger(
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        logger.log(
            .info,
            .test,
            recorder.message("a"),
            attributes: recorder.attributes("a")
        )
        _ = try await logger.flush()

        #expect(sink.enqueuedCount == 1)
        #expect(recorder.count(of: "a") == 2)
        #expect(recorder.callLog == ["message:a", "attributes:a"])
    }

    // MARK: Buffer policies

    @Test(
        ".dropNewest discards the new entry without evaluation and surfaces bufferFull",
        .tags(.axm20)
    )
    func dropNewestDoesNotEvaluateNewEntry() async throws {
        let sink = RecordingAxiomLogSink()
        let unblock = BlockingGate()
        let workerParked = BlockingGate()
        sink.installEnqueueGate(unblock)
        sink.setEnqueueObserver { _ in workerParked.open() }
        let recorder = RecordingEvaluation()
        let diagnostics = DiagnosticCollector()
        let logger = AxiomLogger(
            bufferPolicy: .dropNewest(capacity: 1),
            onDiagnostic: diagnostics.callback,
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        // #1 admitted; worker takes it and parks on `unblock`.
        logger.log(.info, .test, recorder.message("first"), attributes: recorder.attributes("first"))
        await workerParked.wait()
        // #2 admitted, sits in the buffer (capacity 1).
        logger.log(.info, .test, recorder.message("second"), attributes: recorder.attributes("second"))
        // #3 rejected: buffer full, dropNewest. Its autoclosures must
        // not be evaluated.
        logger.log(.info, .test, recorder.message("third"), attributes: recorder.attributes("third"))
        unblock.open()
        _ = try await logger.flush()

        #expect(recorder.count(of: "third") == 0)
        #expect(recorder.count(of: "first") == 2)
        #expect(recorder.count(of: "second") == 2)
        #expect(diagnostics.diagnostics.contains(.bufferFull(dropped: 1)))
        #expect(sink.enqueuedCount == 2)
    }

    @Test(
        ".dropOldest evicts the oldest pending entry without evaluation and admits the new entry",
        .tags(.axm21)
    )
    func dropOldestDoesNotEvaluateEvictedEntry() async throws {
        let sink = RecordingAxiomLogSink()
        let unblock = BlockingGate()
        let workerParked = BlockingGate()
        sink.installEnqueueGate(unblock)
        sink.setEnqueueObserver { _ in workerParked.open() }
        let recorder = RecordingEvaluation()
        let diagnostics = DiagnosticCollector()
        let logger = AxiomLogger(
            bufferPolicy: .dropOldest(capacity: 1),
            onDiagnostic: diagnostics.callback,
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        logger.log(.info, .test, recorder.message("first"), attributes: recorder.attributes("first"))
        await workerParked.wait()
        // Pending after worker parked: []. Admit #2 into pending=[2].
        logger.log(.info, .test, recorder.message("second"), attributes: recorder.attributes("second"))
        // Admit #3: buffer full -> evict oldest (#2) without
        // evaluating, admit #3.
        logger.log(.info, .test, recorder.message("third"), attributes: recorder.attributes("third"))
        unblock.open()
        _ = try await logger.flush()

        #expect(recorder.count(of: "second") == 0)
        #expect(recorder.count(of: "first") == 2)
        #expect(recorder.count(of: "third") == 2)
        #expect(diagnostics.diagnostics.contains(.bufferFull(dropped: 1)))
        #expect(sink.enqueuedCount == 2)
    }

    // MARK: Diagnostics

    @Test(
        "Encoder failure surfaces encodingFailed(String) and skips enqueue",
        .tags(.axm22)
    )
    func encodingFailureSurfacesDiagnostic() async throws {
        let sink = RecordingAxiomLogSink()
        let diagnostics = DiagnosticCollector()
        let logger = AxiomLogger(
            encoder: AlwaysFailingEncoder(),
            onDiagnostic: diagnostics.callback,
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        logger.info(.test, "x")
        _ = try await logger.flush()

        #expect(diagnostics.diagnostics == [.encodingFailed("scripted-fixture-error")])
        #expect(sink.enqueuedCount == 0)
    }

    @Test(
        "Identifier failure surfaces identifierFailed(String) and skips enqueue",
        .tags(.axm23)
    )
    func identifierFailureSurfacesDiagnostic() async throws {
        let sink = RecordingAxiomLogSink()
        let diagnostics = DiagnosticCollector()
        let logger = AxiomLogger(
            identifierProvider: AlwaysFailingIdentifierProvider(),
            onDiagnostic: diagnostics.callback,
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        logger.info(.test, "x")
        _ = try await logger.flush()

        #expect(diagnostics.diagnostics == [.identifierFailed("scripted-fixture-error")])
        #expect(sink.enqueuedCount == 0)
    }

    @Test(
        "Enqueue failure surfaces enqueueFailed(String)",
        .tags(.axm24)
    )
    func enqueueFailureSurfacesDiagnostic() async throws {
        let sink = RecordingAxiomLogSink()
        sink.setEnqueueError(AxiomFixtureError.scripted)
        let diagnostics = DiagnosticCollector()
        let logger = AxiomLogger(
            onDiagnostic: diagnostics.callback,
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        logger.info(.test, "x")
        _ = try await logger.flush()

        #expect(diagnostics.diagnostics == [.enqueueFailed("scripted-fixture-error")])
        #expect(sink.enqueuedCount == 0)
    }

    // MARK: Flush ordering and engine pass-through

    @Test(
        "flush() drains every accepted pending entry before calling engine flush closure",
        .tags(.axm25)
    )
    func flushDrainsAcceptedBeforeEngineFlush() async throws {
        let sink = RecordingAxiomLogSink()
        let gate = BlockingGate()
        let workerParked = BlockingGate()
        let engineFlushAttempted = BlockingGate()
        sink.installEnqueueGate(gate)
        sink.setEnqueueObserver { _ in workerParked.open() }
        sink.setEngineFlushObserver { engineFlushAttempted.open() }
        let logger = AxiomLogger(
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        for index in 1 ... 3 {
            logger.info(.test, "msg-\(index)")
        }

        // Kick the flush task. It should be parked at the drain
        // barrier because the worker is stuck on the gate.
        let flushTask = Task {
            try await logger.flush()
        }
        await workerParked.wait()
        // The engine flush closure must not have been called yet.
        #expect(sink.flushCallCount == 0)

        gate.open()
        await engineFlushAttempted.wait()
        _ = try await flushTask.value

        #expect(sink.enqueuedCount == 3)
        #expect(sink.flushCallCount == 1)
    }

    @Test(
        "Per-caller serial ordering preserved in worker enqueue order",
        .tags(.axm26)
    )
    func perCallerOrderingPreserved() async throws {
        let sink = RecordingAxiomLogSink()
        let logger = AxiomLogger(
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        for index in 1 ... 10 {
            logger.info(.test, "msg-\(index)")
        }
        _ = try await logger.flush()

        let messages = try sink.entries.map { entry -> String in
            let object = try #require(
                JSONSerialization.jsonObject(with: entry.payload) as? [String: Any]
            )
            return try #require(object["message"] as? String)
        }
        #expect(messages == (1 ... 10).map { "msg-\($0)" })
    }

    @Test(
        "Concurrent admissions never produce duplicate identifiers",
        .tags(.axm27)
    )
    func concurrentAdmissionsHaveUniqueIdentifiers() async throws {
        let sink = RecordingAxiomLogSink()
        let logger = AxiomLogger(
            bufferPolicy: .dropNewest(capacity: 10000),
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )
        let admissionCount = 200

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< admissionCount {
                group.addTask {
                    logger.info(.test, "msg-\(index)")
                }
            }
        }
        _ = try await logger.flush()

        let identifiers = sink.entries.map(\.identifier)
        #expect(identifiers.count == admissionCount)
        #expect(Set(identifiers).count == admissionCount)
    }
}
