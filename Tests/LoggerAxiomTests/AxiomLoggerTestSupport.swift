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
    private var engineFlushError: (any Error)?
    private var engineFlushGate: BlockingGate?
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

    /// Scripts an error the engine flush closure throws on every call
    /// instead of returning the configured summary. Passing `nil`
    /// restores the default summary-returning behavior.
    func setEngineFlushError(_ error: (any Error)?) {
        withLock { engineFlushError = error }
    }

    func installEnqueueGate(_ gate: BlockingGate) {
        withLock { enqueueGate = gate }
    }

    /// Gate the engine-flush closure waits on after firing the
    /// observer. Tests use it to park `AxiomLogger.flush()` mid-call
    /// so concurrent service-side behavior is observable.
    func installEngineFlushGate(_ gate: BlockingGate) {
        withLock { engineFlushGate = gate }
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
            let (observer, summary, error, gate) = self.withLock {
                self.engineFlushCallCount += 1
                return (
                    self.engineFlushObserver,
                    self.engineFlushSummaryValue,
                    self.engineFlushError,
                    self.engineFlushGate
                )
            }
            observer?()
            if let gate {
                await gate.wait()
            }
            if let error {
                throw error
            }
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
/// admissions so the test can observe buffer-policy behavior. Once
/// opened, the gate remains permanently open for all future waiters.
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
        withLock { calls }
    }

    func message(_ tag: String) -> LogMessage {
        withLock { calls.append("message:\(tag)") }
        return LogMessage(stringLiteral: "msg-\(tag)")
    }

    func attributes(_ tag: String) -> [LogAttribute] {
        withLock { calls.append("attributes:\(tag)") }
        return [LogAttribute("tag", tag)]
    }

    func count(of tag: String) -> Int {
        callLog.filter { $0.hasSuffix(":\(tag)") }.count
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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

/// Captures every diagnostic an ``AxiomLoggingService`` surfaces
/// through its `onDiagnostic` callback.
final class LoggingServiceDiagnosticCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AxiomLoggingServiceDiagnostic] = []

    var diagnostics: [AxiomLoggingServiceDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var callback: @Sendable (AxiomLoggingServiceDiagnostic) -> Void {
        { [weak self] diagnostic in
            guard let self else { return }
            self.lock.lock()
            self.stored.append(diagnostic)
            self.lock.unlock()
        }
    }
}

/// Parses Swift source text for top-level `import` declarations.
/// Used by platform-independence tests to assert that a source file
/// does not import a forbidden module.
enum SwiftSourceImports {
    /// Returns the set of top-level Swift modules imported by
    /// `source`. Recognizes plain `import X`, attributed forms
    /// (`@preconcurrency import X`, `@_implementationOnly import X`),
    /// kind-qualified forms (`import class X.Y`,
    /// `import struct X.Y`, ...), submodule forms (`import X.Y`),
    /// and tolerates trailing line comments.
    static func modules(in source: String) -> Set<String> {
        let pattern = #"""
        ^\s*(?:@\w+\s+)*import\s+\
        (?:class\s+|struct\s+|enum\s+|protocol\s+|typealias\s+|func\s+|var\s+|let\s+|actor\s+)?\
        ([A-Za-z_][A-Za-z0-9_]*)
        """#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines, .allowCommentsAndWhitespace]
        ) else {
            return []
        }

        // Strip line comments so `import UIKit // note` is detected
        // as importing `UIKit`.
        let stripped = source.split(whereSeparator: \.isNewline)
            .map { line -> Substring in
                guard let commentRange = line.range(of: "//") else { return line }
                return line[..<commentRange.lowerBound]
            }
            .joined(separator: "\n")

        var modules: Set<String> = []
        let range = NSRange(stripped.startIndex ..< stripped.endIndex, in: stripped)
        regex.enumerateMatches(in: stripped, options: [], range: range) { match, _, _ in
            guard let match,
                  let moduleRange = Range(match.range(at: 1), in: stripped)
            else { return }
            modules.insert(String(stripped[moduleRange]))
        }
        return modules
    }
}
