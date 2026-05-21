import Foundation
import Loggers
import Testing

@testable import LoggerAxiom

/// Coverage for ``AxiomDefaultLogEventEncoder``: documented field
/// names, RFC 3339 timestamp shape, privacy redaction for message
/// segments and attribute values, last-wins duplicate-key resolution,
/// and the non-finite-`Double` stable fallback path.
@Suite("AxiomDefaultLogEventEncoder")
struct AxiomDefaultLogEventEncoderTests {
    private static func decode(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private static func referenceTimestamp() -> Date {
        // 2026-05-20T12:34:56.789Z, fixed so the test is independent
        // of the wall clock.
        Date(timeIntervalSince1970: 1_779_280_496.789)
    }

    @Test(
        "Default encoder emits the documented _time / level / domain / message / attributes fields",
        .tags(.axm28)
    )
    func emitsDocumentedFields() throws {
        let encoder = AxiomDefaultLogEventEncoder()
        let event = AxiomLogEvent(
            timestamp: Self.referenceTimestamp(),
            level: .info,
            domain: "Network",
            message: "Request finished",
            attributes: [
                LogAttribute("status", 200),
                LogAttribute("path", "/api/items")
            ]
        )

        let data = try encoder.encode(event)
        let json = try Self.decode(data)

        #expect(json["_time"] as? String == "2026-05-20T12:34:56.789Z")
        #expect(json["level"] as? String == "info")
        #expect(json["domain"] as? String == "Network")
        #expect(json["message"] as? String == "Request finished")
        let attributes = try #require(json["attributes"] as? [String: Any])
        #expect((attributes["status"] as? NSNumber)?.intValue == 200)
        #expect(attributes["path"] as? String == "/api/items")
    }

    @Test(
        "Default encoder renders private and sensitive message segments through the redacted spelling",
        .tags(.axm29)
    )
    func redactsMessageSegments() throws {
        let encoder = AxiomDefaultLogEventEncoder()
        let message: LogMessage = "User \("alice", privacy: .private) opened \("secret-token", privacy: .sensitive)"
        let event = AxiomLogEvent(
            timestamp: Self.referenceTimestamp(),
            level: .info,
            domain: .test,
            message: message,
            attributes: []
        )

        let json = try Self.decode(encoder.encode(event))
        #expect(json["message"] as? String == "User <private> opened <redacted>")
    }

    @Test(
        "Default encoder renders private and sensitive attribute values as the documented string spellings",
        .tags(.axm30)
    )
    func redactsAttributeValues() throws {
        let encoder = AxiomDefaultLogEventEncoder()
        let event = AxiomLogEvent(
            timestamp: Self.referenceTimestamp(),
            level: .info,
            domain: .test,
            message: "x",
            attributes: [
                LogAttribute("public_id", "abc"),
                LogAttribute("user_id", "alice", privacy: .private),
                LogAttribute("token", "xyz", privacy: .sensitive)
            ]
        )

        let json = try Self.decode(encoder.encode(event))
        let attributes = try #require(json["attributes"] as? [String: Any])
        #expect(attributes["public_id"] as? String == "abc")
        #expect(attributes["user_id"] as? String == "<private>")
        #expect(attributes["token"] as? String == "<redacted>")
    }

    @Test(
        "Duplicate attribute keys resolve last-wins in the encoded attributes object",
        .tags(.axm31)
    )
    func duplicateAttributeKeysLastWins() throws {
        let encoder = AxiomDefaultLogEventEncoder()
        let event = AxiomLogEvent(
            timestamp: Self.referenceTimestamp(),
            level: .info,
            domain: .test,
            message: "x",
            attributes: [
                LogAttribute("status", 100),
                LogAttribute("status", 200),
                LogAttribute("status", 503)
            ]
        )

        let json = try Self.decode(encoder.encode(event))
        let attributes = try #require(json["attributes"] as? [String: Any])
        #expect((attributes["status"] as? NSNumber)?.intValue == 503)
    }

    @Test(
        "Non-finite Double values flow through the stable string fallback",
        .tags(.axm28)
    )
    func nonFiniteDoubleFallback() throws {
        let encoder = AxiomDefaultLogEventEncoder()
        let event = AxiomLogEvent(
            timestamp: Self.referenceTimestamp(),
            level: .info,
            domain: .test,
            message: "x",
            attributes: [
                LogAttribute("nan", LogValue.double(.nan)),
                LogAttribute("inf", LogValue.double(.infinity))
            ]
        )

        let json = try Self.decode(encoder.encode(event))
        let attributes = try #require(json["attributes"] as? [String: Any])
        #expect(attributes["nan"] as? String == "nan")
        #expect(attributes["inf"] as? String == "inf")
    }
}
