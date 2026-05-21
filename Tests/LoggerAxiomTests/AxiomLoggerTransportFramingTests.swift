import Foundation
import LoggerRemote
import Loggers
import Testing

@testable import LoggerAxiom

/// Round-trip coverage that the bytes ``AxiomLogger`` enqueues into
/// ``DurableRemoteQueue/enqueue(_:)`` are framed verbatim by the
/// existing ``AxiomIngestRequestBody`` helper into the Axiom ingest
/// JSON array: `[<event_1>,<event_2>,...]`.
@Suite("AxiomLogger / Axiom transport framing")
struct AxiomLoggerTransportFramingTests {
    @Test(
        "Encoded event payload bytes are framed verbatim by AxiomIngestRequestBody",
        .tags(.axm32)
    )
    func encodedPayloadIsFramedVerbatim() async throws {
        let sink = RecordingAxiomLogSink()
        let logger = AxiomLogger(
            enqueue: sink.enqueueClosure,
            engineFlush: sink.engineFlushClosure
        )

        logger.info(.test, "first", attributes: [LogAttribute("i", 1)])
        logger.info(.test, "second", attributes: [LogAttribute("i", 2)])
        _ = try await logger.flush()

        let payloads = sink.entries.map(\.payload)
        #expect(payloads.count == 2)
        let firstPayload = try #require(payloads.first)
        let secondPayload = try #require(payloads.dropFirst().first)
        let framed = AxiomIngestRequestBody.make(events: payloads)
        let firstPayloadRange = try #require(framed.range(of: firstPayload))
        let secondPayloadRange = try #require(framed.range(of: secondPayload))
        #expect(firstPayloadRange.upperBound < secondPayloadRange.lowerBound)

        let parsed = try JSONSerialization.jsonObject(with: framed)
        let array = try #require(parsed as? [[String: Any]])
        #expect(array.count == 2)
        #expect(array[0]["message"] as? String == "first")
        #expect(array[1]["message"] as? String == "second")
    }
}
