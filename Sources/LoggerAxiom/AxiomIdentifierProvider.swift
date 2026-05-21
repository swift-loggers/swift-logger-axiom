import Foundation

/// Identifier seam ``AxiomLogger`` consults inside its internal worker
/// to obtain the
/// `RemoteDeliveryEntry.identifier` for each accepted entry.
///
/// Identifier allocation runs serially in the worker immediately before
/// `DurableRemoteQueue.enqueue(_:)`, so an implementation MAY assume
/// it is invoked from a single context per ``AxiomLogger`` instance.
/// Allocation failures surface to the caller through
/// ``AxiomLoggerDiagnostic/identifierFailed(_:)``; the failing entry is
/// dropped and not enqueued.
///
/// `RemoteDeliveryEntry.identifier` carries no ordering or persistence
/// replay-identity contract by itself; whether the identifier survives
/// app restarts is a property of the provider implementation. The
/// default ``AxiomMonotonicIdentifierProvider`` allocates process-local
/// IDs that reset on every fresh process; consumers that need
/// persistent deduplication identity must supply their own conforming
/// type.
public protocol AxiomIdentifierProvider: Sendable {
    /// Returns the next identifier to assign.
    ///
    /// - Throws: Any error the provider surfaces. The worker projects
    ///   the throw onto ``AxiomLoggerDiagnostic/identifierFailed(_:)``
    ///   with `String(describing: error)`.
    func nextIdentifier() throws -> UInt64
}
