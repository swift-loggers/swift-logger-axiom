import Foundation
import LoggerRemote
import Loggers

@testable import LoggerAxiom

extension LoggerDomain {
    /// Test-target convenience domain used by ``AxiomLogger`` tests.
    static let test: LoggerDomain = "test"
}

/// Sink that records every ``RemoteDeliveryEntry`` the
/// ``AxiomLogger`` worker hands to its `enqueue` closure, plus the
/// summary returned by `engineFlush`. Used by the `AxiomLogger`
/// test suite to drive the storage worker without standing up a
/// persistence-backed durable queue.
final class RecordingAxiomLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RemoteDeliveryEntry] = []
    private var enqueueError: (any Error)?
    private var engineFlushSummaryValue: RemoteFlushSummary = .init(
        attemptedBatches: 0,
        attemptedEntries: 0,
        succeededEntries: 0,
        terminalEntries: 0,
        retryableEntries: 0,
        acknowledgement: .emptyReleased
    )
    private var enqueueGate: BlockingGate?
    private var enqueueObserver: (@Sendable (RemoteDeliveryEntry) -> Void)?
    private var engineFlushObserver: (@Sendable () -> Void)?
    private var engineFlushCallCount: Int = 0

    var entries: [RemoteDeliveryEntry] {
        withLock { stored }
    }

    var enqueuedCount: Int {
        withLock { stored.count }
    }

    var flushCallCount: Int {
        withLock { engineFlushCallCount }
    }

    func setEnqueueError(_ error: (any Error)?) {
        withLock { enqueueError = error }
    }

    func setEngineFlushSummary(_ summary: RemoteFlushSummary) {
        withLock { engineFlushSummaryValue = summary }
    }

    func installEnqueueGate(_ gate: BlockingGate) {
        withLock { enqueueGate = gate }
    }

    /// Closure invoked **before** the enqueue path blocks on the
    /// installed gate or appends the entry. Tests use the observer
    /// to signal `worker has reached enqueue` without polling.
    func setEnqueueObserver(_ observer: (@Sendable (RemoteDeliveryEntry) -> Void)?) {
        withLock { enqueueObserver = observer }
    }

    /// Closure invoked after a flush attempt is recorded and before
    /// the scripted summary is returned.
    func setEngineFlushObserver(_ observer: (@Sendable () -> Void)?) {
        withLock { engineFlushObserver = observer }
    }

    var enqueueClosure: @Sendable (RemoteDeliveryEntry) async throws -> Void {
        { [weak self] entry in
            guard let self else { return }
            let (gate, observer, error) = self.withLock {
                (self.enqueueGate, self.enqueueObserver, self.enqueueError)
            }
            observer?(entry)
            if let gate {
                await gate.wait()
            }
            if let error {
                throw error
            }
            self.withLock {
                self.stored.append(entry)
            }
        }
    }

    var engineFlushClosure: @Sendable () async throws -> RemoteFlushSummary {
        { [weak self] in
            guard let self else {
                return RemoteFlushSummary(
                    attemptedBatches: 0,
                    attemptedEntries: 0,
                    succeededEntries: 0,
                    terminalEntries: 0,
                    retryableEntries: 0,
                    acknowledgement: .emptyReleased
                )
            }
            let (observer, summary) = self.withLock {
                self.engineFlushCallCount += 1
                return (self.engineFlushObserver, self.engineFlushSummaryValue)
            }
            observer?()
            return summary
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Async wait primitive that blocks every caller of ``wait()`` until
/// ``open()`` is invoked. Used to park the storage worker between
/// admissions so the test can observe buffer-policy behavior.
final class BlockingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen: Bool = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// Records every evaluation of a ``Logger`` message / attributes
/// autoclosure as a labeled call so tests can assert evaluation
/// counts per accepted entry.
final class RecordingEvaluation: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    var callLog: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func message(_ tag: String) -> LogMessage {
        lock.lock()
        calls.append("message:\(tag)")
        lock.unlock()
        return LogMessage(stringLiteral: "msg-\(tag)")
    }

    func attributes(_ tag: String) -> [LogAttribute] {
        lock.lock()
        calls.append("attributes:\(tag)")
        lock.unlock()
        return [LogAttribute("tag", tag)]
    }

    func count(of tag: String) -> Int {
        callLog.filter { $0.hasSuffix(":\(tag)") }.count
    }
}

/// Captures every diagnostic the logger surfaces through the
/// `onDiagnostic` callback.
final class DiagnosticCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AxiomLoggerDiagnostic] = []

    var diagnostics: [AxiomLoggerDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var callback: @Sendable (AxiomLoggerDiagnostic) -> Void {
        { [weak self] diagnostic in
            guard let self else { return }
            self.lock.lock()
            self.stored.append(diagnostic)
            self.lock.unlock()
        }
    }
}

/// Encoder that throws on every call. Used to drive the
/// ``AxiomLoggerDiagnostic/encodingFailed(_:)`` path.
struct AlwaysFailingEncoder: AxiomLogEventEncoder {
    let error: AxiomFixtureError

    init(error: AxiomFixtureError = .scripted) {
        self.error = error
    }

    func encode(_: AxiomLogEvent) throws -> Data {
        throw error
    }
}

/// Identifier provider that throws on every call. Used to drive the
/// ``AxiomLoggerDiagnostic/identifierFailed(_:)`` path.
struct AlwaysFailingIdentifierProvider: AxiomIdentifierProvider {
    let error: AxiomFixtureError

    init(error: AxiomFixtureError = .scripted) {
        self.error = error
    }

    func nextIdentifier() throws -> UInt64 {
        throw error
    }
}

/// Stable error fixture so tests assert on `String(describing:)`
/// without depending on Foundation error wrapping.
enum AxiomFixtureError: Error, Equatable, CustomStringConvertible {
    case scripted

    var description: String { "scripted-fixture-error" }
}
