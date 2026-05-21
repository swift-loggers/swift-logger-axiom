/// Diagnostic an ``AxiomLogger`` surfaces through its
/// `onDiagnostic` callback for an admission or worker event that is
/// observable but does not raise from ``AxiomLogger/log(_:_:_:attributes:)``.
///
/// The string payloads carry `String(describing: error)` from the
/// upstream encoder, identifier provider, or queue; they are intended
/// for log telemetry and ad-hoc surface diagnostics rather than for
/// programmatic decisions. Consumers that need typed introspection must
/// inspect their own encoder/identifier/queue stack.
public enum AxiomLoggerDiagnostic: Sendable, Equatable {
    /// The internal pending buffer was full when an entry was offered
    /// for admission. The associated count is the number of entries
    /// dropped on this admission event (`1` per occurrence under the
    /// shipped buffer policies).
    case bufferFull(dropped: Int)

    /// The configured ``AxiomLogEventEncoder`` threw while encoding an
    /// accepted entry. The entry is dropped and never enqueued. The
    /// payload is `String(describing: error)`.
    case encodingFailed(String)

    /// The configured ``AxiomIdentifierProvider`` threw while
    /// allocating an identifier for an accepted entry. The entry is
    /// dropped and never enqueued. The payload is
    /// `String(describing: error)`.
    case identifierFailed(String)

    /// `DurableRemoteQueue.enqueue(_:)` threw for an accepted entry
    /// after encoding and identifier allocation succeeded. The entry
    /// is dropped and not locally retried by the logger; the engine's own
    /// durable-delivery lifecycle is unaffected. The payload is
    /// `String(describing: error)`.
    case enqueueFailed(String)

    /// The internal admission-sequence allocator has issued
    /// `UInt64.max` sequences and has no successor value. The
    /// failing entry is rejected without evaluating its `message`
    /// or `attributes` autoclosures, without evicting any pending
    /// entry, and without advancing the admission counter past its
    /// last issued value. Every subsequent admission on the same
    /// logger fires this diagnostic again.
    case admissionSequenceExhausted
}
