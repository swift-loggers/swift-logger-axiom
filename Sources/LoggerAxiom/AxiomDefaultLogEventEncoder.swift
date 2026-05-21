import Foundation
import Loggers

/// Default ``AxiomLogEventEncoder`` shipped with ``AxiomLogger``.
///
/// Emits one JSON object per event with the following stable field
/// names:
///
/// ```json
/// {
///   "_time": "2026-05-20T12:34:56.789Z",
///   "level": "info",
///   "domain": "Network",
///   "message": "Request finished",
///   "attributes": {
///     "status": 200,
///     "user_id": "<private>"
///   }
/// }
/// ```
///
/// Field contract:
///
/// - `_time` -- RFC 3339 wall-clock string with fractional-second
///   precision (`yyyy-MM-ddTHH:mm:ss.SSSZ`), always UTC.
/// - `level` -- `LoggerLevel.rawValue` of the accepted entry.
/// - `domain` -- `LoggerDomain.rawValue` of the accepted entry.
/// - `message` -- `LogMessage.redactedDescription` (private segments
///   render as `<private>`, sensitive segments render as `<redacted>`).
/// - `attributes` -- JSON object built from the entry's attributes;
///   duplicate keys resolve last-wins. Private attribute values render
///   as the string `<private>`, sensitive values as `<redacted>`.
///   `LogValue` cases map onto JSON primitives; `Date` values use
///   the same RFC 3339 spelling as `_time`; non-finite `Double` values
///   render through the stable fallback path as
///   `String(describing: value)`.
///
/// The encoder never throws for any ``AxiomLogEvent`` constructable
/// from a `Logger` call; unsupported attribute values flow through
/// the stable fallback path rather than failing the entry.
public struct AxiomDefaultLogEventEncoder: AxiomLogEventEncoder {
    public init() {}

    public func encode(_ event: AxiomLogEvent) throws -> Data {
        var object: [String: Any] = [:]
        object["_time"] = Self.formatTimestamp(event.timestamp)
        object["level"] = event.level.rawValue
        object["domain"] = event.domain.rawValue
        object["message"] = event.message.redactedDescription
        object["attributes"] = Self.encodedAttributes(event.attributes)
        return try JSONSerialization.data(
            withJSONObject: object,
            options: []
        )
    }

    private static func encodedAttributes(_ attributes: [LogAttribute]) -> [String: Any] {
        var result: [String: Any] = [:]
        for attribute in attributes {
            result[attribute.key] = encodedValue(
                attribute.value,
                privacy: attribute.privacy
            )
        }
        return result
    }

    private static func encodedValue(_ value: LogValue, privacy: LogPrivacy) -> Any {
        switch privacy {
        case .public:
            return jsonValue(for: value)
        case .private:
            return "<private>"
        case .sensitive:
            return "<redacted>"
        @unknown default:
            // `LogPrivacy` is a non-frozen enum across module
            // boundaries; future cases fall through to the most
            // restrictive rendering so an unannotated value cannot
            // leak verbatim.
            return "<redacted>"
        }
    }

    private static func jsonValue(for value: LogValue) -> Any {
        switch value {
        case let .string(text):
            return text
        case let .integer(integer):
            return NSNumber(value: integer)
        case let .double(double):
            return jsonDouble(double)
        case let .bool(flag):
            return NSNumber(value: flag)
        case let .date(date):
            return formatTimestamp(date)
        case let .array(values):
            return values.map { jsonValue(for: $0) }
        case let .object(dictionary):
            return jsonObject(from: dictionary)
        case .null:
            return NSNull()
        @unknown default:
            // `LogValue` is a non-frozen enum across module
            // boundaries; future cases flow through the stable
            // string fallback so the entry stays encodable.
            return String(describing: value)
        }
    }

    /// JSONSerialization rejects NaN / ±infinity; the stable
    /// fallback keeps the entry encodable instead of failing the
    /// whole event.
    private static func jsonDouble(_ double: Double) -> Any {
        if double.isFinite {
            return NSNumber(value: double)
        }
        return String(describing: double)
    }

    private static func jsonObject(from dictionary: [String: LogValue]) -> [String: Any] {
        var nested: [String: Any] = [:]
        for (key, value) in dictionary {
            nested[key] = jsonValue(for: value)
        }
        return nested
    }

    private static func formatTimestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// Process-wide RFC 3339 UTC formatter with fractional-second
    /// precision.
    private static let timestampFormatter = LockedISO8601Formatter()

    /// Thread-safe wrapper around `ISO8601DateFormatter`.
    private final class LockedISO8601Formatter: @unchecked Sendable {
        private let lock = NSLock()
        private let formatter: ISO8601DateFormatter

        init() {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            self.formatter = formatter
        }

        func string(from date: Date) -> String {
            lock.lock()
            defer { lock.unlock() }
            return formatter.string(from: date)
        }
    }
}
