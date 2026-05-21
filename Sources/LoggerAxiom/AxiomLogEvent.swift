import Foundation
import Loggers

/// The materialized payload an ``AxiomLogEventEncoder`` consumes when an
/// ``AxiomLogger`` accepted pending entry is processed by the internal
/// worker.
///
/// The worker captures the call-site timestamp at admission, evaluates
/// the `Logger` autoclosures once, and assembles the result as an
/// `AxiomLogEvent` before handing it to the configured encoder. The
/// type carries no transport-level metadata; the host-side encoder is
/// the only authority over the wire shape of each Axiom event document.
public struct AxiomLogEvent: Sendable, Equatable {
    /// Wall-clock time captured when the entry was admitted to the
    /// logger's internal buffer.
    public let timestamp: Date

    /// Severity of the entry. Never `LoggerLevel.disabled` for an
    /// accepted pending entry; the drop guard inside
    /// ``AxiomLogger/log(_:_:_:attributes:)`` rejects that sentinel
    /// before admission.
    public let level: LoggerLevel

    /// Subsystem the entry belongs to.
    public let domain: LoggerDomain

    /// Structured message payload evaluated from the call-site
    /// autoclosure.
    public let message: LogMessage

    /// Structured attributes evaluated from the call-site autoclosure,
    /// preserved in call-site order.
    public let attributes: [LogAttribute]

    /// Creates an event.
    ///
    /// - Parameters:
    ///   - timestamp: Admission-time wall-clock.
    ///   - level: Severity of the entry.
    ///   - domain: Subsystem the entry belongs to.
    ///   - message: Structured message payload.
    ///   - attributes: Structured attributes, in call-site order.
    public init(
        timestamp: Date,
        level: LoggerLevel,
        domain: LoggerDomain,
        message: LogMessage,
        attributes: [LogAttribute]
    ) {
        self.timestamp = timestamp
        self.level = level
        self.domain = domain
        self.message = message
        self.attributes = attributes
    }
}
