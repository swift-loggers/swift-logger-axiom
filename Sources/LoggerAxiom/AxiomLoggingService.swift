import Foundation
import LoggerRemote

/// Drives an ``AxiomLogger``'s ``AxiomLogger/flush()`` on a
/// host-chosen cadence.
///
/// ``AxiomLoggingService`` imports no UIKit / AppKit / SwiftUI /
/// WatchKit and subscribes to no process-lifecycle notification on
/// its own. Host code drives ``start()`` and ``stop()`` from
/// whatever lifecycle hooks it already manages.
public final class AxiomLoggingService: Sendable {
    private let storage: Storage

    public init(
        logger: AxiomLogger,
        flushPolicy: AxiomFlushPolicy = .periodic(seconds: 30),
        onDiagnostic: (@Sendable (AxiomLoggingServiceDiagnostic) -> Void)? = nil
    ) {
        storage = Storage(
            logger: logger,
            flushPolicy: flushPolicy,
            onDiagnostic: onDiagnostic
        )
    }

    /// Starts the periodic flush loop under
    /// ``AxiomFlushPolicy/periodic(seconds:)``; a no-op under
    /// ``AxiomFlushPolicy/manual`` or after ``stop()``. Idempotent.
    public func start() {
        storage.start()
    }

    /// Stops the periodic loop and performs one final
    /// ``AxiomLogger/flush()`` before returning. A throw from the
    /// final flush surfaces as
    /// ``AxiomLoggingServiceDiagnostic/flushFailed(_:)`` instead of
    /// re-throwing. Concurrent and subsequent calls return only
    /// after the in-flight stop's final flush has completed; the
    /// final flush runs exactly once per service instance.
    public func stop() async {
        await storage.stop()
    }

    /// Forwards to ``AxiomLogger/flush()``.
    ///
    /// - Returns: The `RemoteFlushSummary` reported by the engine.
    /// - Throws: Re-throws any error from ``AxiomLogger/flush()``.
    @discardableResult
    public func flush() async throws -> RemoteFlushSummary {
        try await storage.flush()
    }

    private final class Storage: @unchecked Sendable {
        private let logger: AxiomLogger
        private let flushPolicy: AxiomFlushPolicy
        private let onDiagnostic: (@Sendable (AxiomLoggingServiceDiagnostic) -> Void)?

        private let lock = NSLock()
        private var periodicTask: Task<Void, Never>?
        private var started: Bool = false
        /// `nil` until the first ``stop()`` call; afterwards holds the
        /// single task that runs the cancel + final-flush sequence.
        /// Concurrent and subsequent ``stop()`` callers `await` this
        /// task's value so they return only after the final flush
        /// has completed; the final flush runs exactly once.
        private var stopTask: Task<Void, Never>?

        init(
            logger: AxiomLogger,
            flushPolicy: AxiomFlushPolicy,
            onDiagnostic: (@Sendable (AxiomLoggingServiceDiagnostic) -> Void)?
        ) {
            self.logger = logger
            self.flushPolicy = flushPolicy
            self.onDiagnostic = onDiagnostic
        }

        deinit {
            // The periodic loop captures `logger` and `onDiagnostic`
            // by value and does not retain `Storage`, so a service
            // deallocated without `stop()` would otherwise leak a
            // flushing task. Cancellation is best-effort: it
            // interrupts the loop's next `Task.sleep` and prevents
            // further iteration, but any flush already in flight
            // when `deinit` runs completes on its own. The final
            // flush remains a `stop()`-only contract.
            periodicTask?.cancel()
        }

        func start() {
            var invalidInterval: TimeInterval?

            lock.lock()
            if started || stopTask != nil {
                lock.unlock()
                return
            }
            started = true

            switch flushPolicy {
            case .manual:
                lock.unlock()
                return
            case let .periodic(seconds):
                if let nanoseconds = Self.validatedNanoseconds(seconds: seconds) {
                    let logger = logger
                    let onDiagnostic = onDiagnostic
                    // The lock stays held across `Task { ... }` so a
                    // concurrent `stop()` cannot observe
                    // `periodicTask == nil` and skip cancellation.
                    periodicTask = Task {
                        await Self.runPeriodic(
                            nanoseconds: nanoseconds,
                            logger: logger,
                            onDiagnostic: onDiagnostic
                        )
                    }
                    lock.unlock()
                } else {
                    invalidInterval = seconds
                    lock.unlock()
                }
            }

            if let invalidInterval {
                onDiagnostic?(.invalidFlushInterval(seconds: invalidInterval))
            }
        }

        func stop() async {
            await joinOrLaunchStop().value
        }

        /// Returns the single stop-running task. The first caller
        /// installs it under the lock; concurrent and subsequent
        /// callers receive the same task and `await` its value so
        /// `stop()` only returns after the final flush completes.
        /// `stopTask` is also the "stopped" sentinel that
        /// ``start()`` consults to skip launching a new periodic
        /// loop.
        private func joinOrLaunchStop() -> Task<Void, Never> {
            lock.lock()
            if let existing = stopTask {
                lock.unlock()
                return existing
            }
            let taskToCancel = periodicTask
            periodicTask = nil
            let logger = logger
            let onDiagnostic = onDiagnostic
            let task = Task {
                taskToCancel?.cancel()
                await taskToCancel?.value
                do {
                    _ = try await logger.flush()
                } catch {
                    onDiagnostic?(.flushFailed(String(describing: error)))
                }
            }
            stopTask = task
            lock.unlock()
            return task
        }

        func flush() async throws -> RemoteFlushSummary {
            try await logger.flush()
        }

        private static func runPeriodic(
            nanoseconds: UInt64,
            logger: AxiomLogger,
            onDiagnostic: (@Sendable (AxiomLoggingServiceDiagnostic) -> Void)?
        ) async {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                do {
                    _ = try await logger.flush()
                } catch {
                    onDiagnostic?(.flushFailed(String(describing: error)))
                }
            }
        }

        /// Translates a configured periodic interval into a positive
        /// nanosecond count usable by `Task.sleep(nanoseconds:)`, or
        /// `nil` for every value that would otherwise degenerate
        /// into an immediate-retry loop: non-finite, non-positive,
        /// and sub-nanosecond positives that truncate to zero.
        private static func validatedNanoseconds(seconds: TimeInterval) -> UInt64? {
            guard seconds.isFinite, seconds > 0 else { return nil }
            let nanos = seconds * 1_000_000_000
            guard nanos < Double(UInt64.max) else { return .max }
            let truncated = UInt64(nanos)
            return truncated > 0 ? truncated : nil
        }
    }
}
