import Foundation

/// Encoder seam that maps an ``AxiomLogEvent`` to the opaque
/// pre-encoded payload bytes ``AxiomLogger`` hands to
/// `DurableRemoteQueue.enqueue(_:)`.
///
/// Each call must return one complete JSON value (typically a JSON
/// object) so the framing helper in ``AxiomRemoteEngine`` can wrap
/// every batch round's payload bytes into the Axiom ingest array
/// `[<event_1>,...,<event_n>]` without further interpretation.
///
/// Encoder failures surface to the caller through
/// ``AxiomLoggerDiagnostic/encodingFailed(_:)``; the failing entry is
/// dropped and not enqueued.
public protocol AxiomLogEventEncoder: Sendable {
    /// Encodes one event into pre-encoded payload bytes.
    ///
    /// - Parameter event: The accepted pending entry the worker
    ///   materialized.
    /// - Returns: One complete JSON value the Axiom framing helper
    ///   places into the request body verbatim.
    /// - Throws: Any error the encoder surfaces. The worker projects
    ///   the throw onto ``AxiomLoggerDiagnostic/encodingFailed(_:)``
    ///   with `String(describing: error)`.
    func encode(_ event: AxiomLogEvent) throws -> Data
}
