import Foundation

/// Diagnostic an ``AxiomLoggingService`` surfaces through its
/// `onDiagnostic` callback for flush failures that are not
/// re-thrown and for invalid service configuration accepted at
/// ``AxiomLoggingService/start()`` time.
public enum AxiomLoggingServiceDiagnostic: Sendable, Equatable {
    /// A periodic flush or the final flush inside
    /// ``AxiomLoggingService/stop()`` threw. The payload is
    /// `String(describing: error)`. The periodic loop continues
    /// running after a periodic flush failure. Errors are stringified
    /// to keep diagnostics fully `Sendable` and stable across
    /// actor / task boundaries.
    case flushFailed(String)

    /// ``AxiomLoggingService/start()`` was called with
    /// ``AxiomFlushPolicy/periodic(seconds:)`` carrying an
    /// interval that is non-positive, non-finite, or so small
    /// that it truncates to zero nanoseconds. The payload is the
    /// offending interval value.
    case invalidFlushInterval(seconds: TimeInterval)

    public static func == (
        lhs: AxiomLoggingServiceDiagnostic,
        rhs: AxiomLoggingServiceDiagnostic
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.flushFailed(left), .flushFailed(right)):
            return left == right
        case let (.invalidFlushInterval(left), .invalidFlushInterval(right)):
            // Treat `.nan` as equal to itself so the diagnostic is
            // reflexively equatable for any value the caller can
            // pass in `.periodic(seconds:)`.
            return (left.isNaN && right.isNaN) || left == right
        default:
            return false
        }
    }
}
