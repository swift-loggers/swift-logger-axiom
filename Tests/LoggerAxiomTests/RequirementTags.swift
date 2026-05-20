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
}
