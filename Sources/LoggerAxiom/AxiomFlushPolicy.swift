import Foundation

/// Cadence ``AxiomLoggingService`` applies to its periodic flush
/// loop.
public enum AxiomFlushPolicy: Sendable, Equatable {
    /// No periodic loop runs; the host drives every flush through
    /// ``AxiomLoggingService/flush()``.
    case manual

    /// The service sleeps `seconds` between flushes. `seconds` must
    /// be finite, positive, and large enough to round to at least
    /// one nanosecond. Validation is performed by
    /// ``AxiomLoggingService/start()``.
    case periodic(seconds: TimeInterval)

    public static func == (lhs: AxiomFlushPolicy, rhs: AxiomFlushPolicy) -> Bool {
        switch (lhs, rhs) {
        case (.manual, .manual):
            return true
        case let (.periodic(left), .periodic(right)):
            // Treat `.nan` as equal to itself so the enum is
            // reflexively equatable even when a caller supplies an
            // invalid interval; otherwise IEEE 754 makes
            // `.periodic(seconds: .nan) != .periodic(seconds: .nan)`.
            return (left.isNaN && right.isNaN) || left == right
        default:
            return false
        }
    }
}
