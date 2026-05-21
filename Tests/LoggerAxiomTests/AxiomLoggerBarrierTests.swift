import Foundation
import LoggerRemote
import Loggers
import Testing

@testable import LoggerAxiom

/// Targeted barrier-correctness coverage for the
/// ``AxiomLoggerStorage`` flush barrier. The suite stresses the
/// out-of-order resolution path: a `.dropOldest`-evicted later
/// sequence must not bump `processedSequence` past an older accepted
/// sequence that is still in-flight on the worker.
@Suite("AxiomLogger barrier correctness")
struct AxiomLoggerBarrierTests {
    @Test(
        "flush() barrier does not resume on a .dropOldest eviction while an older accepted entry is still in-flight",
        .tags(.axm21, .axm25)
    )
    func dropOldestEvictionDoesNotResumeBarrierAheadOfInFlightEntry() async throws {
        let sink = RecordingAxiomLogSink()
        let unblock = BlockingGate()
        let workerParked = BlockingGate()
        let barrierParked = BlockingGate()
        let barrierResolutions = BarrierResolutionRecorder()
        sink.installEnqueueGate(unblock)
        sink.setEnqueueObserver { _ in workerParked.open() }
        let logger = AxiomLogger(
            bufferPolicy: .dropOldest(capacity: 1),
            onFlushBarrierParked: { target in
                if target == 2 {
                    barrierParked.open()
                }
            },
            onFlushBarrierResolved: barrierResolutions.record,
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        // seq1 admitted; worker takes it and parks on `unblock`. The
        // worker is now processing an accepted entry that is no
        // longer in the buffer.
        logger.info(.test, "first")
        await workerParked.wait()

        // seq2 admitted, sits in the buffer.
        logger.info(.test, "second")

        // Park a flush() at the drain barrier with target = 2.
        let flushTask = Task {
            try await logger.flush()
        }
        await barrierParked.wait()

        // seq3 admitted: buffer full, .dropOldest evicts seq2. The
        // bug would mark seq2 resolved with a bare max() bump,
        // resuming the target=2 barrier even though seq1 is still
        // in-flight on the worker.
        logger.info(.test, "third")
        #expect(barrierResolutions.targets.isEmpty)
        #expect(sink.flushCallCount == 0)

        // Releasing seq1 lets the worker drain seq1 and resume the
        // barrier; the target=2 barrier resolves as soon as seq1
        // finishes (seq2 was evicted, so the contiguous prefix walks
        // through it). engineFlush must have run before flushTask
        // returns.
        unblock.open()
        _ = try await flushTask.value
        #expect(barrierResolutions.targets == [2])
        #expect(sink.flushCallCount == 1)

        // Drain seq3 to completion through a fresh barrier so the
        // suite leaves no in-flight worker behind.
        _ = try await logger.flush()
        #expect(sink.enqueuedCount == 2)
    }

    @Test(
        ".dropOldest under sustained backpressure drains correctly and bounds enqueued work to capacity + in-flight",
        .tags(.axm21, .axm25)
    )
    func dropOldestUnderSustainedBackpressureDrainsCorrectly() async throws {
        let sink = RecordingAxiomLogSink()
        let unblock = BlockingGate()
        let workerParked = BlockingGate()
        sink.installEnqueueGate(unblock)
        sink.setEnqueueObserver { _ in workerParked.open() }
        let capacity = 4
        let logger = AxiomLogger(
            bufferPolicy: .dropOldest(capacity: capacity),
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        // seq1 admitted; worker takes it and parks on `unblock`.
        logger.info(.test, "first")
        await workerParked.wait()

        // Stream many admissions. Under `.dropOldest`, every
        // subsequent admission past capacity evicts the pending
        // front. The storage's resolved-ahead bookkeeping must stay
        // O(1) — a per-sequence set would grow linearly with this
        // loop and the prefix walk on `unblock.open()` would have
        // to remove that many entries before resuming the flush
        // barrier.
        let admissionCount = 5000
        for index in 2 ... admissionCount {
            logger.info(.test, "msg-\(index)")
        }

        unblock.open()
        _ = try await logger.flush()

        // Worker enqueued seq1 plus the `capacity` entries that
        // remained pending after the eviction storm. Everything in
        // between was evicted without evaluation.
        #expect(sink.enqueuedCount == capacity + 1)
    }
}

private final class BarrierResolutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UInt64] = []

    var targets: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var record: @Sendable (UInt64) -> Void {
        { [weak self] target in
            guard let self else { return }
            self.lock.lock()
            self.stored.append(target)
            self.lock.unlock()
        }
    }
}
