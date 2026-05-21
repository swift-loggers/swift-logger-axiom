import Foundation

/// Process-local monotonic ``AxiomIdentifierProvider`` shipped with
/// ``AxiomLogger`` as the default.
///
/// Allocates `UInt64` identifiers starting at `1` and increasing by one
/// per call. The counter is owned by the provider instance and resets
/// every time a fresh process constructs the provider; identifiers are
/// not durable across app restarts. Consumers that need persistent
/// deduplication identity across launches must supply their own
/// ``AxiomIdentifierProvider`` implementation.
///
/// Allocation is internally serialized so the provider is safe to share
/// across loggers; in practice ``AxiomLogger`` invokes it from a single
/// internal worker.
public struct AxiomMonotonicIdentifierProvider: AxiomIdentifierProvider {
    private let storage: Storage

    public init() {
        storage = Storage()
    }

    public func nextIdentifier() throws -> UInt64 {
        try storage.next()
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var nextValue: UInt64 = 1

        func next() throws -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            guard nextValue != 0 else {
                throw AxiomMonotonicIdentifierError.exhausted
            }
            let value = nextValue
            nextValue &+= 1
            return value
        }
    }
}

/// Errors ``AxiomMonotonicIdentifierProvider`` raises through the
/// ``AxiomIdentifierProvider/nextIdentifier()`` seam.
public enum AxiomMonotonicIdentifierError: Error, Sendable, Equatable {
    /// The provider issued `UInt64.max` identifiers and has no
    /// successor value to allocate. The next call surfaces this case
    /// through ``AxiomLoggerDiagnostic/identifierFailed(_:)``.
    case exhausted
}
