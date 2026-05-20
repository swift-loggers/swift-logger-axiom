import Foundation
import Testing

@testable import LoggerAxiom

@Suite("AxiomIngestRequestBody framing")
struct AxiomIngestRequestBodyTests {
    private static func makeEventBytes(_ message: String) -> Data {
        Data(#"{"msg":"\#(message)"}"#.utf8)
    }

    @Test(
        "Single event produces a one-element JSON array",
        .tags(.axm1, .axm2)
    )
    func singleEvent() throws {
        let body = AxiomIngestRequestBody.make(events: [Self.makeEventBytes("hello")])

        let expected = Data(#"[{"msg":"hello"}]"#.utf8)
        #expect(body == expected)
    }

    @Test(
        "Multiple events are framed as a JSON array in input order",
        .tags(.axm2, .axm5)
    )
    func multipleEventsAreFramedInInputOrder() throws {
        let body = AxiomIngestRequestBody.make(events: [
            Self.makeEventBytes("one"),
            Self.makeEventBytes("two"),
            Self.makeEventBytes("three")
        ])

        let expected = Data(#"[{"msg":"one"},{"msg":"two"},{"msg":"three"}]"#.utf8)
        #expect(body == expected)
    }

    @Test(
        "Empty event array produces empty body",
        .tags(.axm2)
    )
    func emptyEventsProduceEmptyBody() throws {
        let body = AxiomIngestRequestBody.make(events: [])

        #expect(body.isEmpty)
    }

    @Test(
        "Event payload bytes appear verbatim inside the JSON array",
        .tags(.axm1, .axm2)
    )
    func eventPayloadIsAppendedVerbatim() throws {
        let payload = Data(#"{"deeply":{"nested":[1,2,3]}}"#.utf8)
        let body = AxiomIngestRequestBody.make(events: [payload])

        // `[` + payload + `]`. The adapter does not mutate, escape,
        // or re-encode the host-provided event bytes.
        let expected = Data([0x5B]) + payload + Data([0x5D])
        #expect(body == expected)
    }

    @Test(
        "Body wraps events in a JSON array without a per-event metadata envelope",
        .tags(.axm2)
    )
    func noMetadataEnvelope() throws {
        let body = AxiomIngestRequestBody.make(
            events: [Self.makeEventBytes("hello")]
        )

        // The adapter does NOT wrap events in any per-event
        // metadata envelope; the host-provided JSON value appears
        // in the array verbatim.
        let parsed = try JSONSerialization.jsonObject(with: body) as? [[String: Any]]
        try #require(parsed?.count == 1)
        #expect((parsed?[0]["msg"] as? String) == "hello")
        #expect(parsed?[0]["event"] == nil)
        #expect(parsed?[0]["source"] == nil)
        #expect(parsed?[0]["sourcetype"] == nil)
        #expect(parsed?[0]["index"] == nil)
    }
}
