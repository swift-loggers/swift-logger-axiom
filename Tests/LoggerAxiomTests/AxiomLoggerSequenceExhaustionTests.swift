import Foundation
import LoggerRemote
import Loggers
import Testing

@testable import LoggerAxiom

/// Boundary coverage for the admission-sequence allocator: an
/// ``AxiomLogger`` whose internal `acceptedSequence` has reached
/// `UInt64.max` must reject further admissions without wrapping
/// the counter, evaluating call-site closures, evicting a pending
/// entry, or blocking ``AxiomLogger/flush()``.
@Suite("AxiomLogger admission-sequence exhaustion")
struct AxiomLoggerSequenceExhaustionTests {
    @Test(
        "Exhausted admission sequence rejects new entry, never evaluates closures, never wraps the counter",
        .tags(.axm34)
    )
    func exhaustedSequenceRejectsAdmission() async throws {
        let sink = RecordingAxiomLogSink()
        let recorder = RecordingEvaluation()
        let diagnostics = DiagnosticCollector()
        // Seed both `acceptedSequence` and `processedSequence` at
        // `UInt64.max` so the flush barrier is trivially satisfied
        // (no in-flight entry, no resolved-ahead gap) and the test
        // does not depend on a worker running.
        let logger = AxiomLogger(
            onDiagnostic: diagnostics.callback,
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure,
            initialAcceptedSequence: UInt64.max,
            initialProcessedSequence: UInt64.max
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
        #expect(diagnostics.diagnostics == [.admissionSequenceExhausted])
    }

    @Test(
        "Every subsequent admission past exhaustion fires the diagnostic again",
        .tags(.axm34)
    )
    func exhaustedSequenceFiresDiagnosticEveryAdmission() async throws {
        let sink = RecordingAxiomLogSink()
        let diagnostics = DiagnosticCollector()
        let logger = AxiomLogger(
            onDiagnostic: diagnostics.callback,
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure,
            initialAcceptedSequence: UInt64.max,
            initialProcessedSequence: UInt64.max
        )

        for _ in 0 ..< 3 {
            logger.info(.test, "x")
        }
        _ = try await logger.flush()

        #expect(sink.enqueuedCount == 0)
        #expect(diagnostics.diagnostics == [
            .admissionSequenceExhausted,
            .admissionSequenceExhausted,
            .admissionSequenceExhausted
        ])
    }
}
