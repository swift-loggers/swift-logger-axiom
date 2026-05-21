import Testing

/// Swift Testing tags for `Docs/Requirements.md` requirement IDs.
///
/// One tag per AXM ID; tags without test references are retained so
/// the catalog stays 1:1 with the spec.
extension Tag {
    // MARK: Payload contract

    /// Lazy host-side encoding boundary; payload bytes are opaque
    /// pre-encoded JSON values.
    @Tag public static var axm1: Self
    /// JSON array request body framing: `[<event_1>,<event_2>,...]`,
    /// events in input order, no metadata envelope wrapped around
    /// individual events.
    @Tag public static var axm2: Self

    // MARK: `RemoteTransport.sendBatch(_:)` contract

    /// One Axiom request per non-empty `sendBatch(_:)` call; empty
    /// `items` returns `[]` and dispatches no Axiom request.
    @Tag public static var axm3: Self
    /// One result per input item.
    @Tag public static var axm4: Self
    /// Input-order preservation across results and request body.
    @Tag public static var axm5: Self
    /// 2xx success projection (active item / batch-round scope):
    /// every active item in the batch round resolves to `.success`
    /// carrying opaque response bytes.
    @Tag public static var axm6: Self
    /// Whole-batch failure projection: `sendBatch(_:)` throw routes
    /// through `classify(_:)` for every active item.
    @Tag public static var axm7: Self

    // MARK: Classification policy

    /// Retryable mapping: HTTP 408 / 429 / 5xx, `invalidResponse`,
    /// arbitrary errors, and unexpected statuses.
    @Tag public static var axm8: Self
    /// Terminal mapping: HTTP 401 / 403 and other HTTP 4xx.
    @Tag public static var axm9: Self
    /// Deterministic classification with no queue / export-state
    /// mutation; repeated `classify(_:)` invocations for the same
    /// result within a flush pass return the same decision.
    @Tag public static var axm10: Self

    // MARK: Endpoint trust model

    /// Direct Axiom builds `Authorization: Bearer <token>`; URL sent
    /// verbatim.
    @Tag public static var axm11: Self
    /// Intake passes `Authorization` verbatim or omits when `nil`;
    /// URL sent verbatim.
    @Tag public static var axm12: Self

    // MARK: Engine lifecycle ownership

    /// Caller-driven flush lifecycle (public engine surface scope):
    /// `RemoteEngine.flush()` is caller-driven; no autonomous
    /// scheduler, platform lifecycle observer, or timer.
    @Tag public static var axm13: Self
    /// Retained outstanding batch reuse for the retained outstanding
    /// batch across flush passes; no fresh drain while an
    /// outstanding batch is retained.
    @Tag public static var axm14: Self
    /// Acknowledgement-to-removal lifecycle: ack only on pass-wide
    /// `.success` / `.terminal` resolution.
    @Tag public static var axm15: Self

    // MARK: `AxiomLogger` admission and worker

    /// `AxiomLogger(wiring:)` constructable with the default encoder
    /// and default identifier provider; accepted entry is eventually
    /// enqueued through `DurableRemoteQueue.enqueue(_:)` and
    /// `flush()` invokes the engine flush closure.
    @Tag public static var axm16: Self
    /// `LoggerLevel.disabled` drop guard never evaluates message or
    /// attributes autoclosures and fires no diagnostic callback.
    @Tag public static var axm17: Self
    /// Below-minimum drop guard never evaluates message or
    /// attributes autoclosures and fires no diagnostic callback.
    @Tag public static var axm18: Self
    /// Accepted entry evaluates message and attributes exactly once.
    @Tag public static var axm19: Self
    /// `.dropNewest` drops the new entry without evaluating its
    /// autoclosures and fires `bufferFull(dropped:)`.
    @Tag public static var axm20: Self
    /// `.dropOldest` drops the oldest pending entry without
    /// evaluating it, admits the new entry, and fires
    /// `bufferFull(dropped:)`.
    @Tag public static var axm21: Self
    /// Encoder failure surfaces `encodingFailed(String)`; the entry
    /// is not enqueued.
    @Tag public static var axm22: Self
    /// Identifier failure surfaces `identifierFailed(String)`; the
    /// entry is not enqueued.
    @Tag public static var axm23: Self
    /// Enqueue failure surfaces `enqueueFailed(String)`.
    @Tag public static var axm24: Self
    /// `flush()` drains every accepted pending entry before calling
    /// the engine flush closure.
    @Tag public static var axm25: Self
    /// Per-caller serial admission ordering is preserved in the
    /// worker's enqueue order.
    @Tag public static var axm26: Self
    /// Concurrent admissions never produce duplicate identifiers.
    @Tag public static var axm27: Self

    // MARK: Default encoder

    /// Default encoder emits the documented JSON field names
    /// (`_time`, `level`, `domain`, `message`, `attributes`).
    @Tag public static var axm28: Self
    /// Default encoder renders private message segments as
    /// `<private>` and sensitive segments as `<redacted>`.
    @Tag public static var axm29: Self
    /// Default encoder renders private attribute values as the
    /// string `<private>` and sensitive values as `<redacted>`.
    @Tag public static var axm30: Self
    /// Duplicate attribute keys resolve last-wins in the encoded
    /// `attributes` object.
    @Tag public static var axm31: Self
    /// Encoded event payload bytes are framed verbatim by the
    /// existing Axiom request body helper without additional
    /// logger-side metadata envelope or wrapping.
    @Tag public static var axm32: Self
    /// Threshold uses the nested `AxiomLogger.MinimumLevel` enum
    /// (seven severities); `LoggerLevel.disabled` is not
    /// expressible as a threshold through the public API.
    @Tag public static var axm33: Self
    /// Admission-sequence exhaustion: `acceptedSequence` never
    /// wraps past `UInt64.max`; further admissions are rejected
    /// without evaluating closures or evicting pending entries
    /// and surface
    /// `AxiomLoggerDiagnostic.admissionSequenceExhausted`.
    @Tag public static var axm34: Self

    // MARK: `AxiomLoggingService`

    /// `start()` is idempotent: repeated calls launch a single
    /// internal periodic loop.
    @Tag public static var axm35: Self
    /// `AxiomFlushPolicy.manual` starts no periodic loop; explicit
    /// `flush()` and the final flush in `stop()` are the only
    /// flushes the service drives.
    @Tag public static var axm36: Self
    /// `AxiomFlushPolicy.periodic(seconds:)` starts one internal
    /// periodic loop that drives `AxiomLogger.flush()`.
    @Tag public static var axm37: Self
    /// Periodic flushes are serially scheduled in a single internal
    /// task; the next sleep begins only after the previous flush
    /// returns. No two periodic flushes overlap.
    @Tag public static var axm38: Self
    /// `AxiomLoggingService.flush()` forwards to `AxiomLogger.flush()`
    /// and returns its `RemoteFlushSummary` or rethrows the
    /// underlying error.
    @Tag public static var axm39: Self
    /// `AxiomLoggingService.stop()` cancels the periodic loop,
    /// awaits its exit, and performs exactly one final
    /// `AxiomLogger.flush()` before returning. Subsequent calls are
    /// no-ops.
    @Tag public static var axm40: Self
    /// A throw from the periodic flush surfaces
    /// `AxiomLoggingServiceDiagnostic.flushFailed(_:)`; the periodic
    /// loop continues.
    @Tag public static var axm41: Self
    /// A throw from the final flush inside `stop()` surfaces
    /// `AxiomLoggingServiceDiagnostic.flushFailed(_:)` instead of
    /// re-throwing.
    @Tag public static var axm42: Self
    /// `AxiomLoggingService` introduces no UIKit / AppKit / SwiftUI /
    /// WatchKit dependency.
    @Tag public static var axm43: Self
    /// `.periodic(seconds:)` with a non-positive, non-finite, or
    /// sub-nanosecond interval starts no periodic loop and
    /// surfaces
    /// `AxiomLoggingServiceDiagnostic.invalidFlushInterval(seconds:)`;
    /// the service behaves as `.manual` thereafter.
    @Tag public static var axm44: Self
    /// Deallocating an `AxiomLoggingService` cancels its periodic
    /// loop; cancellation prevents any further iteration but does
    /// not abort an in-flight flush.
    @Tag public static var axm45: Self
}
