import Foundation
import LoggerRemote
import Testing

@testable import LoggerAxiom

/// End-to-end integration coverage for the M4.1 Axiom HTTP ingest
/// <-> `swift-logger-remote` wiring.
///
/// Each test stands up an isolated temp queue + export directory,
/// builds the engine through ``AxiomRemoteEngine/make(_:ingestTransport:)``
/// with a scripted HTTP seam, runs the public enqueue / flush
/// lifecycle, and asserts the engine-facing `RemoteFlushSummary`
/// outcome. The HTTP layer is replaced by a recorder so the test is
/// deterministic and network-free, but the engine path itself --
/// the durable queue, batch-round dispatch, per-item classification,
/// and acknowledgement-to-removal lifecycle -- is fully real.
@Suite("AxiomRemoteEngine integration")
struct AxiomRemoteEngineIntegrationTests {
    private static func uniqueDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggerAxiomIntegrationTests")
            .appendingPathComponent(UUID().uuidString)
    }

    private static func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
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

    @Test(
        "flush: all items accepted (2xx) -> ACK removes delivered bytes",
        .tags(.axm6, .axm13, .axm15)
    )
    func flushAllAcceptedAcknowledges() async throws {
        let (queueDir, exportDir) = try Self.makeDirectories()
        defer {
            Self.cleanup(queueDir)
            Self.cleanup(exportDir)
        }

        let recorder = RecordingAxiomIngestTransport()
        recorder.setResponseBody(Data(#"{"ingested":3,"failed":0}"#.utf8))
        let configuration = try Self.makeConfiguration(
            queueDirectory: queueDir, exportDirectory: exportDir
        )
        let wiring = AxiomRemoteEngine.make(configuration, ingestTransport: recorder)

        for index in 1 ... 3 {
            try await wiring.queue.enqueue(RemoteDeliveryEntry(
                identifier: UInt64(index),
                payload: Data(#"{"i":\#(index)}"#.utf8)
            ))
        }

        let summary = try await wiring.engine.flush()
        #expect(summary.attemptedBatches == 1)
        #expect(summary.succeededEntries == 3)
        #expect(summary.terminalEntries == 0)
        #expect(summary.retryableEntries == 0)
        #expect(summary.acknowledgement == .removedDeliveredBytes)
        #expect(recorder.sentCount == 1)

        // Follow-up flush: after `.removedDeliveredBytes` the
        // persistence layer dropped the delivered queue payload
        // bytes, so the next `flush()` finds the queue empty.
        let second = try await wiring.engine.flush()
        #expect(second.attemptedBatches == 0)
        #expect(second.acknowledgement == .emptyReleased)
        #expect(recorder.sentCount == 1)
    }

    @Test(
        "flush: retryable (5xx) holds outstanding batch and skips fresh drain on next flush",
        .tags(.axm7, .axm10, .axm14, .axm15)
    )
    func flushRetryableHoldsOutstandingBatch() async throws {
        let (queueDir, exportDir) = try Self.makeDirectories()
        defer {
            Self.cleanup(queueDir)
            Self.cleanup(exportDir)
        }

        let recorder = RecordingAxiomIngestTransport()
        // Two scripted 503s drain the retry budget (maxAttempts = 2)
        // within the first flush pass, leaving the entries
        // classified retryable so the engine holds the outstanding
        // batch and the next flush reuses it through the
        // outstanding-batch path.
        recorder.setErrors([
            AxiomIngestTransportError.unsuccessfulStatus(503),
            AxiomIngestTransportError.unsuccessfulStatus(503)
        ])
        let configuration = try Self.makeConfiguration(
            queueDirectory: queueDir, exportDirectory: exportDir
        )
        let wiring = AxiomRemoteEngine.make(configuration, ingestTransport: recorder)

        for index in 1 ... 2 {
            try await wiring.queue.enqueue(RemoteDeliveryEntry(
                identifier: UInt64(index),
                payload: Data(#"{"i":\#(index)}"#.utf8)
            ))
        }

        let first = try await wiring.engine.flush()
        #expect(first.attemptedBatches == 1)
        #expect(first.retryableEntries == 2)
        #expect(first.succeededEntries == 0)
        #expect(first.acknowledgement == .notAcknowledged)
        #expect(recorder.sentCount == 0)

        // Recover scripted by feeding the recorder a 2xx response
        // for the follow-up flush. The engine should reuse the
        // outstanding batch (no fresh drain) and acknowledge once
        // every entry resolves.
        recorder.setResponseBody(Data(#"{"ingested":2,"failed":0}"#.utf8))

        // Enqueue one extra entry between flushes. The
        // outstanding-batch reuse rule means the engine must NOT
        // drain a new batch including this entry; only the
        // already-drained batch from the prior flush is reused
        // through the outstanding-batch path.
        try await wiring.queue.enqueue(RemoteDeliveryEntry(
            identifier: 99,
            payload: Data(#"{"i":99}"#.utf8)
        ))

        let second = try await wiring.engine.flush()
        #expect(second.attemptedBatches == 1)
        // The retained outstanding batch still has only 2 entries,
        // NOT 3 -- the extra entry stayed queued because the engine
        // refused to drain a fresh batch while an outstanding batch
        // was retained.
        #expect(second.succeededEntries == 2)
        #expect(second.retryableEntries == 0)
        #expect(second.acknowledgement == .removedDeliveredBytes)

        // Now drain the queued tail entry on a fresh flush.
        let third = try await wiring.engine.flush()
        #expect(third.attemptedBatches == 1)
        #expect(third.succeededEntries == 1)
        #expect(third.acknowledgement == .removedDeliveredBytes)
    }

    @Test(
        "flush: terminal-only items (4xx) still ACK (pass-wide resolution rule)",
        .tags(.axm7, .axm9, .axm15)
    )
    func flushTerminalItemsAcknowledges() async throws {
        let (queueDir, exportDir) = try Self.makeDirectories()
        defer {
            Self.cleanup(queueDir)
            Self.cleanup(exportDir)
        }

        let recorder = RecordingAxiomIngestTransport()
        recorder.setErrors([
            AxiomIngestTransportError.unsuccessfulStatus(401)
        ])
        let configuration = try Self.makeConfiguration(
            queueDirectory: queueDir, exportDirectory: exportDir
        )
        let wiring = AxiomRemoteEngine.make(configuration, ingestTransport: recorder)

        for index in 1 ... 3 {
            try await wiring.queue.enqueue(RemoteDeliveryEntry(
                identifier: UInt64(index),
                payload: Data(#"{"i":\#(index)}"#.utf8)
            ))
        }

        let summary = try await wiring.engine.flush()
        #expect(summary.succeededEntries == 0)
        #expect(summary.terminalEntries == 3)
        #expect(summary.retryableEntries == 0)
        #expect(summary.acknowledgement == .removedDeliveredBytes)
        #expect(recorder.sentCount == 0)

        let second = try await wiring.engine.flush()
        #expect(second.attemptedBatches == 0)
        #expect(second.acknowledgement == .emptyReleased)
    }
}
