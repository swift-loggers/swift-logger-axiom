/// Bounded-buffer policy ``AxiomLogger`` applies when the internal
/// pending buffer is full at admission time.
///
/// The capacity argument is the maximum number of accepted pending
/// entries the buffer holds at once. Values below `1` are clamped to
/// `1` by ``AxiomLogger`` so a buffer always admits at least one entry.
public enum AxiomLoggerBufferPolicy: Sendable, Equatable {
    /// When the buffer is full, drops the new entry without evaluating
    /// its `message` or `attributes` autoclosures. The buffer keeps the
    /// oldest entries.
    case dropNewest(capacity: Int)

    /// When the buffer is full, drops the oldest pending entry without
    /// evaluating it and admits the new entry for later worker
    /// evaluation. The buffer keeps the newest entries.
    case dropOldest(capacity: Int)
}

extension AxiomLoggerBufferPolicy {
    /// The capacity associated with the policy case.
    var capacity: Int {
        switch self {
        case let .dropNewest(capacity): return capacity
        case let .dropOldest(capacity): return capacity
        }
    }
}
