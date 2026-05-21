import Foundation
import LoggerRemote
import Loggers

/// Batteries-included `Loggers.Logger` adapter that admits log entries
/// non-blockingly and forwards them to an Axiom-bound durable delivery
/// engine.
///
/// ``AxiomLogger`` wraps the ``AxiomRemoteEngine`` wiring with a
/// bounded admission buffer, a single internal serial worker, a
/// pluggable ``AxiomLogEventEncoder``, and a pluggable
/// ``AxiomIdentifierProvider``. ``log(_:_:_:attributes:)`` returns to
/// the caller without awaiting the queue: the call evaluates the level
/// drop guard, admits the entry into the bounded buffer (or rejects it
/// per ``AxiomLoggerBufferPolicy``), and returns. The internal worker
/// then materializes each accepted entry, allocates its identifier,
/// encodes it, and hands the resulting payload bytes to
/// `DurableRemoteQueue.enqueue(_:)` in admission order.
///
/// ## Drop guards
///
/// Two drop guards run before any closure is evaluated:
///
/// - Entries tagged `LoggerLevel.disabled` are rejected
///   unconditionally.
/// - Entries whose level is below the configured `minimumLevel` are
///   rejected.
///
/// A third drop guard applies under
/// ``AxiomLoggerBufferPolicy/dropNewest(capacity:)`` when the buffer
/// is full: the new entry is rejected without evaluating its
/// `message` or `attributes` autoclosures. Under
/// ``AxiomLoggerBufferPolicy/dropOldest(capacity:)`` the oldest
/// pending entry is evicted (also without evaluating it) and the new
/// entry is admitted.
///
/// ## Ordering and identifiers
///
/// Admission preserves per-caller serial ordering: a caller that emits
/// two entries in sequence sees them processed in that order by the
/// worker. No global ordering guarantee is made across concurrent
/// callers. Identifiers are monotonic in worker dequeue order, not in
/// wall-clock call order; under contention an entry admitted slightly
/// later may receive an earlier identifier than one admitted slightly
/// earlier on a different caller.
///
/// ## Flush
///
/// ``flush()`` waits until every entry already admitted at the moment
/// of the call has either been enqueued onto the durable queue or
/// produced a diagnostic failure (encoding, identifier allocation, or
/// queue enqueue), then runs `RemoteEngine.flush()`. Entries dropped
/// at admission are not waited on because they were never accepted.
///
/// ## Diagnostics
///
/// Buffer drops, encoder failures, identifier failures, and queue
/// enqueue failures surface through the `onDiagnostic` callback as
/// ``AxiomLoggerDiagnostic`` values. The string payloads use
/// `String(describing: error)`. The callback runs **synchronously
/// on the caller's `log(_:_:_:attributes:)` path** for
/// ``AxiomLoggerDiagnostic/bufferFull(dropped:)`` and **on the
/// internal worker context** for
/// ``AxiomLoggerDiagnostic/encodingFailed(_:)``,
/// ``AxiomLoggerDiagnostic/identifierFailed(_:)``, and
/// ``AxiomLoggerDiagnostic/enqueueFailed(_:)``. The closure must
/// satisfy the `@Sendable` contract in both cases.
public struct AxiomLogger: Logger {
    /// Severity threshold accepted by an ``AxiomLogger`` instance.
    ///
    /// Mirrors the seven `Loggers.LoggerLevel` severities and
    /// intentionally excludes the per-message `LoggerLevel.disabled`
    /// sentinel: a threshold is not a per-message drop signal.
    /// The cross-adapter contract requires every thresholded adapter
    /// to expose its own `MinimumLevel` enum with exactly these
    /// seven cases.
    public enum MinimumLevel: String, CaseIterable, Sendable {
        case trace
        case debug
        case info
        case notice
        case warning
        case error
        case critical

        var loggerLevel: LoggerLevel {
            switch self {
            case .trace: return .trace
            case .debug: return .debug
            case .info: return .info
            case .notice: return .notice
            case .warning: return .warning
            case .error: return .error
            case .critical: return .critical
            }
        }
    }

    private let storage: AxiomLoggerStorage
    private let minimumLevel: LoggerLevel

    /// Creates a logger that admits entries into a bounded internal
    /// buffer and forwards them to `wiring.queue` through a single
    /// serial worker.
    ///
    /// - Parameters:
    ///   - wiring: ``AxiomRemoteEngine/Wiring`` carrying the durable
    ///     queue the worker enqueues into and the engine ``flush()``
    ///     drives.
    ///   - encoder: ``AxiomLogEventEncoder`` invoked per accepted
    ///     entry. Defaults to ``AxiomDefaultLogEventEncoder``.
    ///   - identifierProvider: ``AxiomIdentifierProvider`` invoked
    ///     per accepted entry. Defaults to
    ///     ``AxiomMonotonicIdentifierProvider``.
    ///   - bufferPolicy: Bounded-buffer policy applied at admission.
    ///     A capacity below `1` is clamped to `1`.
    ///   - minimumLevel: Severity threshold the logger applies before
    ///     evaluating any autoclosure. Pass ``MinimumLevel/trace`` to
    ///     accept every severity.
    ///   - onDiagnostic: Optional callback. Buffer-drop diagnostics
    ///     fire synchronously on the caller's
    ///     ``log(_:_:_:attributes:)`` path; encoder, identifier, and
    ///     queue enqueue failures fire on the internal worker
    ///     context.
    public init(
        wiring: AxiomRemoteEngine.Wiring,
        encoder: any AxiomLogEventEncoder = AxiomDefaultLogEventEncoder(),
        identifierProvider: any AxiomIdentifierProvider = AxiomMonotonicIdentifierProvider(),
        bufferPolicy: AxiomLoggerBufferPolicy = .dropNewest(capacity: 1000),
        minimumLevel: MinimumLevel = .trace,
        onDiagnostic: (@Sendable (AxiomLoggerDiagnostic) -> Void)? = nil
    ) {
        let queue = wiring.queue
        let engine = wiring.engine
        self.init(
            encoder: encoder,
            identifierProvider: identifierProvider,
            bufferPolicy: bufferPolicy,
            minimumLevel: minimumLevel,
            onDiagnostic: onDiagnostic,
            enqueue: { entry in try await queue.enqueue(entry) },
            engineFlush: { try await engine.flush() }
        )
    }

    /// Test-only initializer that decouples the storage from the
    /// concrete ``AxiomRemoteEngine/Wiring`` so the test target can
    /// inject scripted enqueue and flush behavior without standing up
    /// a persistence-backed queue.
    internal init(
        encoder: any AxiomLogEventEncoder = AxiomDefaultLogEventEncoder(),
        identifierProvider: any AxiomIdentifierProvider = AxiomMonotonicIdentifierProvider(),
        bufferPolicy: AxiomLoggerBufferPolicy = .dropNewest(capacity: 1000),
        minimumLevel: MinimumLevel = .trace,
        onDiagnostic: (@Sendable (AxiomLoggerDiagnostic) -> Void)? = nil,
        onFlushBarrierParked: (@Sendable (UInt64) -> Void)? = nil,
        onFlushBarrierResolved: (@Sendable (UInt64) -> Void)? = nil,
        enqueue: @escaping @Sendable (RemoteDeliveryEntry) async throws -> Void,
        engineFlush: @escaping @Sendable () async throws -> RemoteFlushSummary,
        initialAcceptedSequence: UInt64 = 0,
        initialProcessedSequence: UInt64 = 0
    ) {
        self.minimumLevel = minimumLevel.loggerLevel
        storage = AxiomLoggerStorage(
            encoder: encoder,
            identifierProvider: identifierProvider,
            bufferPolicy: bufferPolicy,
            onDiagnostic: onDiagnostic,
            onFlushBarrierParked: onFlushBarrierParked,
            onFlushBarrierResolved: onFlushBarrierResolved,
            enqueue: enqueue,
            engineFlush: engineFlush,
            initialAcceptedSequence: initialAcceptedSequence,
            initialProcessedSequence: initialProcessedSequence
        )
    }

    public func log(
        _ level: LoggerLevel,
        _ domain: LoggerDomain,
        _ message: @autoclosure @escaping @Sendable () -> LogMessage,
        attributes: @autoclosure @escaping @Sendable () -> [LogAttribute]
    ) {
        guard level != .disabled, level >= minimumLevel else { return }
        storage.tryAdmit(
            level: level,
            domain: domain,
            messageProvider: message,
            attributesProvider: attributes
        )
    }

    /// Waits until every entry already admitted at the moment of the
    /// call is either enqueued onto the durable queue or has produced
    /// a diagnostic failure, then runs `RemoteEngine.flush()`.
    ///
    /// - Returns: The `RemoteFlushSummary` reported by the engine.
    /// - Throws: `RemoteEngineError` propagated verbatim from the
    ///   engine's flush pass.
    public func flush() async throws -> RemoteFlushSummary {
        try await storage.flush()
    }
}
