import Foundation
import LoggerRemote
import Loggers

/// Internal state container backing ``AxiomLogger``.
///
/// Owns the bounded pending buffer, the admission sequence counter, the
/// flush barriers, the diagnostic callback, and the single worker
/// `Task` that materializes each accepted entry by allocating its
/// identifier, encoding it, and enqueueing it through the host-supplied
/// enqueue closure. Producers admit through ``tryAdmit(...)`` under a
/// lock; the worker consumes pending entries one at a time from the
/// same lock-protected buffer. A single-element `AsyncStream<Void>`
/// wakes the worker from idle.
///
/// The class is reference-typed and `@unchecked Sendable`: every
/// mutable field is guarded by the internal lock, except the wake
/// continuation and the worker task which are immutable references to
/// concurrency-safe Foundation/Swift primitives.
final class AxiomLoggerStorage: @unchecked Sendable {
    private struct PendingEvent: Sendable {
        let sequence: UInt64
        let timestamp: Date
        let level: LoggerLevel
        let domain: LoggerDomain
        let messageProvider: @Sendable () -> LogMessage
        let attributesProvider: @Sendable () -> [LogAttribute]
    }

    /// FIFO queue of ``PendingEvent`` values.
    private struct PendingQueue {
        private static let compactionThreshold = 64

        private var buffer: [PendingEvent?] = []
        private var head: Int = 0

        var count: Int { buffer.count - head }

        mutating func append(_ event: PendingEvent) {
            buffer.append(event)
        }

        mutating func popFirst() -> PendingEvent? {
            guard head < buffer.count, let event = buffer[head] else {
                return nil
            }
            buffer[head] = nil
            head += 1
            compactIfNeeded()
            return event
        }

        private mutating func compactIfNeeded() {
            guard head >= Self.compactionThreshold, head * 2 >= buffer.count else {
                return
            }
            buffer.removeFirst(head)
            head = 0
        }
    }

    private struct FlushBarrier {
        let target: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private let capacity: Int
    private let policy: AxiomLoggerBufferPolicy
    private let onDiagnostic: (@Sendable (AxiomLoggerDiagnostic) -> Void)?
    private let encoder: any AxiomLogEventEncoder
    private let identifierProvider: any AxiomIdentifierProvider
    private let enqueue: @Sendable (RemoteDeliveryEntry) async throws -> Void
    private let engineFlush: @Sendable () async throws -> RemoteFlushSummary
    private let onFlushBarrierParked: (@Sendable (UInt64) -> Void)?
    private let onFlushBarrierResolved: (@Sendable (UInt64) -> Void)?
    private let wakeContinuation: AsyncStream<Void>.Continuation
    private var workerTask: Task<Void, Never>?

    private let lock = NSLock()
    private var pending = PendingQueue()
    private var acceptedSequence: UInt64 = 0
    private var processedSequence: UInt64 = 0
    /// Lower bound of the resolved-ahead contiguous range; `0`
    /// signals an empty range. See ``advanceResolvedPrefix(adding:)``
    /// for the invariant.
    private var resolvedAheadStart: UInt64 = 0
    /// Upper bound of the resolved-ahead contiguous range; `0`
    /// signals an empty range.
    private var resolvedAheadEnd: UInt64 = 0
    private var flushBarriers: [FlushBarrier] = []

    init(
        encoder: any AxiomLogEventEncoder,
        identifierProvider: any AxiomIdentifierProvider,
        bufferPolicy: AxiomLoggerBufferPolicy,
        onDiagnostic: (@Sendable (AxiomLoggerDiagnostic) -> Void)?,
        onFlushBarrierParked: (@Sendable (UInt64) -> Void)? = nil,
        onFlushBarrierResolved: (@Sendable (UInt64) -> Void)? = nil,
        enqueue: @escaping @Sendable (RemoteDeliveryEntry) async throws -> Void,
        engineFlush: @escaping @Sendable () async throws -> RemoteFlushSummary,
        initialAcceptedSequence: UInt64 = 0,
        initialProcessedSequence: UInt64 = 0
    ) {
        self.encoder = encoder
        self.identifierProvider = identifierProvider
        policy = bufferPolicy
        capacity = Swift.max(1, bufferPolicy.capacity)
        self.onDiagnostic = onDiagnostic
        self.onFlushBarrierParked = onFlushBarrierParked
        self.onFlushBarrierResolved = onFlushBarrierResolved
        self.enqueue = enqueue
        self.engineFlush = engineFlush
        acceptedSequence = initialAcceptedSequence
        processedSequence = initialProcessedSequence
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        wakeContinuation = continuation
        workerTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await drainPending()
            }
        }
    }

    deinit {
        wakeContinuation.finish()
        workerTask?.cancel()
    }

    // MARK: - Admission

    /// Synchronous admission entry point invoked by
    /// ``AxiomLogger/log(_:_:_:attributes:)``.
    ///
    /// The drop guard for `LoggerLevel.disabled` and below-minimum
    /// entries runs at the call site **before** this function is
    /// invoked, so the rejected-without-evaluation contract is owned
    /// by ``AxiomLogger`` directly. Buffer-full admissions are
    /// resolved here: ``AxiomLoggerBufferPolicy/dropNewest(capacity:)``
    /// rejects the new entry without evaluating its autoclosures;
    /// ``AxiomLoggerBufferPolicy/dropOldest(capacity:)`` evicts the
    /// oldest pending entry (also without evaluating it) and admits
    /// the new entry for later worker evaluation.
    func tryAdmit(
        level: LoggerLevel,
        domain: LoggerDomain,
        messageProvider: @escaping @Sendable () -> LogMessage,
        attributesProvider: @escaping @Sendable () -> [LogAttribute]
    ) {
        var resumedBarriers: [FlushBarrier] = []
        var shouldFireBufferFull = false
        var shouldFireSequenceExhausted = false
        var didAdmit = false

        lock.lock()
        if acceptedSequence == UInt64.max {
            shouldFireSequenceExhausted = true
        } else if pending.count >= capacity {
            switch policy {
            case .dropNewest:
                shouldFireBufferFull = true
            case .dropOldest:
                if let evicted = pending.popFirst() {
                    advanceResolvedPrefix(adding: evicted.sequence)
                }
                resumedBarriers = drainFlushBarriers()
                shouldFireBufferFull = true
                didAdmit = true
            }
        } else {
            didAdmit = true
        }

        if didAdmit {
            acceptedSequence &+= 1
            pending.append(PendingEvent(
                sequence: acceptedSequence,
                timestamp: Date(),
                level: level,
                domain: domain,
                messageProvider: messageProvider,
                attributesProvider: attributesProvider
            ))
        }
        lock.unlock()

        if didAdmit {
            wakeContinuation.yield()
        }
        if shouldFireBufferFull {
            onDiagnostic?(.bufferFull(dropped: 1))
        }
        if shouldFireSequenceExhausted {
            onDiagnostic?(.admissionSequenceExhausted)
        }
        for barrier in resumedBarriers {
            onFlushBarrierResolved?(barrier.target)
            barrier.continuation.resume()
        }
    }

    // MARK: - Flush

    /// Drains every accepted pending entry through the worker, then
    /// runs the remote-engine flush. The drain barrier captures the
    /// admission sequence at call time so an admission made after this
    /// call started does not extend the wait.
    func flush() async throws -> RemoteFlushSummary {
        await waitForAcceptedDrain()
        return try await engineFlush()
    }

    private func waitForAcceptedDrain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var parkedTarget: UInt64?
            lock.lock()
            let target = acceptedSequence
            if processedSequence >= target {
                lock.unlock()
                continuation.resume()
                return
            }
            flushBarriers.append(FlushBarrier(
                target: target,
                continuation: continuation
            ))
            parkedTarget = target
            lock.unlock()
            if let parkedTarget {
                onFlushBarrierParked?(parkedTarget)
            }
            // Wake the worker in case it is parked between events; a
            // pending entry that admitted before this barrier may
            // still be sitting in the buffer.
            wakeContinuation.yield()
        }
    }

    // MARK: - Worker

    private func drainPending() async {
        while let event = takeNext() {
            await process(event)
            markProcessed(sequence: event.sequence)
        }
    }

    private func takeNext() -> PendingEvent? {
        lock.lock()
        defer { lock.unlock() }
        return pending.popFirst()
    }

    private func process(_ event: PendingEvent) async {
        let materialized = AxiomLogEvent(
            timestamp: event.timestamp,
            level: event.level,
            domain: event.domain,
            message: event.messageProvider(),
            attributes: event.attributesProvider()
        )
        let payload: Data
        do {
            payload = try encoder.encode(materialized)
        } catch {
            onDiagnostic?(.encodingFailed(String(describing: error)))
            return
        }
        let identifier: UInt64
        do {
            identifier = try identifierProvider.nextIdentifier()
        } catch {
            onDiagnostic?(.identifierFailed(String(describing: error)))
            return
        }
        do {
            try await enqueue(RemoteDeliveryEntry(
                identifier: identifier,
                payload: payload
            ))
        } catch {
            onDiagnostic?(.enqueueFailed(String(describing: error)))
        }
    }

    private func markProcessed(sequence: UInt64) {
        let resumed: [FlushBarrier]
        lock.lock()
        advanceResolvedPrefix(adding: sequence)
        resumed = drainFlushBarriers()
        lock.unlock()
        for barrier in resumed {
            onFlushBarrierResolved?(barrier.target)
            barrier.continuation.resume()
        }
    }

    /// Records `sequence` as no longer pending (worker-processed or
    /// `.dropOldest`-evicted) and advances `processedSequence` along
    /// the contiguous resolved prefix.
    ///
    /// **Why:** flush-barrier targets capture
    /// `acceptedSequence` at call time. Releasing a barrier requires
    /// every accepted sequence at or below the target to have left
    /// the in-flight surface; a non-contiguous bump would resume a
    /// barrier while an older worker-in-flight entry is still
    /// running.
    ///
    /// **Structural invariant.** The single-FIFO worker takes pending
    /// in strictly-increasing sequence order, `.dropOldest` evicts
    /// pending's front (also strictly-increasing), and at most one
    /// sequence is in-flight at a time. Resolutions therefore form a
    /// contiguous range ahead of `processedSequence`, growing either
    /// at its upper end (next eviction or worker take) or at its
    /// lower end (worker finishing the in-flight that was held back
    /// while evictions ran ahead of it). Storing the range as
    /// `[resolvedAheadStart, resolvedAheadEnd]` keeps the bookkeeping
    /// O(1) even when `.dropOldest` evicts an unbounded number of
    /// entries while the in-flight sequence is slow to enqueue.
    ///
    /// Caller must hold ``lock``.
    private func advanceResolvedPrefix(adding sequence: UInt64) {
        guard sequence > processedSequence else { return }

        if resolvedAheadStart == 0 {
            resolvedAheadStart = sequence
            resolvedAheadEnd = sequence
        } else if sequence == resolvedAheadEnd &+ 1 {
            resolvedAheadEnd = sequence
        } else if resolvedAheadStart > 0, sequence == resolvedAheadStart &- 1 {
            resolvedAheadStart = sequence
        } else if sequence >= resolvedAheadStart, sequence <= resolvedAheadEnd {
            // Already inside the range. Defensive against an idempotent
            // re-call; expected paths admit each sequence exactly once.
            return
        } else {
            // Non-adjacent insertion would imply a regression of the
            // single-FIFO admission contract. Hold the existing range
            // unchanged so the flush barrier waits rather than
            // resuming on a phantom prefix.
            return
        }

        if resolvedAheadStart == processedSequence &+ 1 {
            processedSequence = resolvedAheadEnd
            resolvedAheadStart = 0
            resolvedAheadEnd = 0
        }
    }

    /// Splits any flush barriers whose target sequence is now
    /// satisfied off the pending barrier list and returns them. Caller
    /// must hold ``lock``.
    private func drainFlushBarriers() -> [FlushBarrier] {
        var resumed: [FlushBarrier] = []
        var remaining: [FlushBarrier] = []
        for barrier in flushBarriers {
            if barrier.target <= processedSequence {
                resumed.append(barrier)
            } else {
                remaining.append(barrier)
            }
        }
        flushBarriers = remaining
        return resumed
    }
}
