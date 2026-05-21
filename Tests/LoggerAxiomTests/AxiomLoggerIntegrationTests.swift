import Foundation
import LoggerRemote
import Loggers
import Testing

@testable import LoggerAxiom

/// End-to-end coverage that the public ``AxiomLogger/init(wiring:encoder:identifierProvider:bufferPolicy:minimumLevel:onDiagnostic:)``
/// initializer with **no overrides** compiles and delivers an
/// admitted entry through the durable queue all the way to the
/// Axiom ingest transport. Proves every default argument (encoder,
/// identifier provider, buffer policy, minimum level, diagnostic
/// callback) is reachable at the public call site.
@Suite("AxiomLogger default-wiring integration")
struct AxiomLoggerIntegrationTests {
    private static func uniqueDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggerAxiomLoggerIntegrationTests")
            .appendingPathComponent(UUID().uuidString)
    }

    private static func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func makeDirectories() throws -> (queue: URL, export: URL) {
        let queueDir = uniqueDirectory()
        let exportDir = uniqueDirectory()
        try FileManager.default.createDirectory(
            at: queueDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: exportDir, withIntermediateDirectories: true
        )
        return (queueDir, exportDir)
    }

    private static func makeConfiguration(
        queueDirectory: URL,
        exportDirectory: URL
    ) throws -> AxiomRemoteEngine.Configuration {
        let ingestURL = try #require(
            URL(string: "https://api.axiom.test/v1/datasets/demo/ingest")
        )
        let batchPolicy = try RemoteBatchPolicy.make(
            maxEntryCount: 100,
            maxByteCount: 64 * 1024
        )
        let retryPolicy = try RemoteRetryPolicy.make(
            maxAttempts: 2,
            backoff: .exponential(
                initialSeconds: 0.01, multiplier: 2, capSeconds: 0.05
            )
        )
        return AxiomRemoteEngine.Configuration(
            endpoint: .axiom(url: ingestURL, token: "test-token"),
            queueDirectory: queueDirectory,
            exportDirectory: exportDirectory,
            batchPolicy: batchPolicy,
            retryPolicy: retryPolicy
        )
    }

    @Test(
        "AxiomLogger(wiring:) with defaults compiles and delivers an admitted entry to the ingest transport",
        .tags(.axm16)
    )
    func defaultWiringInitDeliversAdmittedEntry() async throws {
        let (queueDir, exportDir) = try Self.makeDirectories()
        defer {
            Self.cleanup(queueDir)
            Self.cleanup(exportDir)
        }

        let recorder = RecordingAxiomIngestTransport()
        recorder.setResponseBody(Data(#"{"ingested":1,"failed":0}"#.utf8))
        let configuration = try Self.makeConfiguration(
            queueDirectory: queueDir, exportDirectory: exportDir
        )
        let wiring = AxiomRemoteEngine.make(configuration, ingestTransport: recorder)

        // Public init reaches every defaulted argument: encoder
        // (`AxiomDefaultLogEventEncoder`), identifier provider
        // (`AxiomMonotonicIdentifierProvider`), buffer policy,
        // minimum level, and the (absent) diagnostic callback.
        let logger = AxiomLogger(wiring: wiring)

        logger.info(.test, "hello, axiom", attributes: [LogAttribute("k", "v")])
        let summary = try await logger.flush()

        #expect(summary.attemptedEntries == 1)
        #expect(summary.succeededEntries == 1)
        #expect(summary.acknowledgement == .removedDeliveredBytes)
        #expect(recorder.sentCount == 1)

        // Default encoder's JSON shape reaches the transport through
        // the durable queue + Axiom request framing.
        let sent = try #require(recorder.sent.first)
        let array = try #require(
            JSONSerialization.jsonObject(with: sent.body) as? [[String: Any]]
        )
        #expect(array.count == 1)
        #expect(array[0]["message"] as? String == "hello, axiom")
        #expect(array[0]["level"] as? String == "info")
        #expect(array[0]["domain"] as? String == "test")
        let attributes = try #require(array[0]["attributes"] as? [String: Any])
        #expect(attributes["k"] as? String == "v")
    }
}
