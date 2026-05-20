import Foundation
import LoggerRemote
import Testing

@testable import LoggerAxiom

/// Coverage for ``AxiomRemoteTransport`` as a `RemoteTransport`
/// conformer.
///
/// The suite drives the adapter through the seam-injected
/// ``RecordingAxiomIngestTransport`` so each test fully scripts the
/// HTTP response (or the absence of one) and asserts the per-item
/// `Result` projection plus the engine-facing ``classify(_:)``
/// mapping. None of the tests touch the network.
@Suite("AxiomRemoteTransport batch dispatch")
struct AxiomRemoteTransportTests {
    private static let directURLString = "https://api.axiom.test/v1/datasets/demo/ingest"
    private static let intakeURLString = "https://logs.example.test/axiom"

    private static func makeDirectAdapter(
        transport: RecordingAxiomIngestTransport
    ) throws -> AxiomRemoteTransport {
        let url = try #require(URL(string: directURLString))
        return AxiomRemoteTransport(
            endpoint: .axiom(url: url, token: "test-token"),
            transport: transport
        )
    }

    private static func makeIntakeAdapter(
        transport: RecordingAxiomIngestTransport,
        authorizationHeader: String? = "Bearer test"
    ) throws -> AxiomRemoteTransport {
        let url = try #require(URL(string: intakeURLString))
        return AxiomRemoteTransport(
            endpoint: .intake(url: url, authorizationHeader: authorizationHeader),
            transport: transport
        )
    }

    private static func batchItem(_ payload: String) -> RemoteTransportBatchItem {
        RemoteTransportBatchItem(payloadBytes: Data(payload.utf8))
    }

    // MARK: request shape

    @Test(
        "sendBatch builds exactly one Axiom ingest request per call",
        .tags(.axm3)
    )
    func sendBatchBuildsOneRequest() async throws {
        let recorder = RecordingAxiomIngestTransport()
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = (1 ... 5).map { Self.batchItem(#"{"i":\#($0)}"#) }

        _ = try await adapter.sendBatch(items)

        #expect(recorder.sentCount == 1)
    }

    @Test(
        "Empty batch is a no-op: returns [] and dispatches no Axiom request",
        .tags(.axm3, .axm4)
    )
    func emptyBatchIsNoOp() async throws {
        let recorder = RecordingAxiomIngestTransport()
        let adapter = try Self.makeDirectAdapter(transport: recorder)

        let results = try await adapter.sendBatch([])

        #expect(results.isEmpty)
        #expect(recorder.sentCount == 0)
    }

    @Test(
        "Direct request sends Authorization: Bearer <token> + JSON Content-Type",
        .tags(.axm11)
    )
    func directRequestCarriesBearerAuthAndJSONContentType() async throws {
        let recorder = RecordingAxiomIngestTransport()
        let adapter = try Self.makeDirectAdapter(transport: recorder)

        _ = try await adapter.sendBatch([Self.batchItem(#"{"i":1}"#)])

        let sent = try #require(recorder.sent.first)
        #expect(sent.headers["Authorization"] == "Bearer test-token")
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(sent.url.absoluteString == Self.directURLString)
    }

    @Test(
        "Intake request passes Authorization header through verbatim",
        .tags(.axm12)
    )
    func intakeRequestCarriesVerbatimAuthorization() async throws {
        let recorder = RecordingAxiomIngestTransport()
        let adapter = try Self.makeIntakeAdapter(
            transport: recorder,
            authorizationHeader: "Bearer xyz"
        )

        _ = try await adapter.sendBatch([Self.batchItem(#"{"i":1}"#)])

        let sent = try #require(recorder.sent.first)
        #expect(sent.headers["Authorization"] == "Bearer xyz")
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(sent.url.absoluteString == Self.intakeURLString)
    }

    @Test(
        "Intake with nil authorization header omits Authorization entirely",
        .tags(.axm12)
    )
    func intakeNilAuthorizationOmitsHeader() async throws {
        let recorder = RecordingAxiomIngestTransport()
        let adapter = try Self.makeIntakeAdapter(
            transport: recorder,
            authorizationHeader: nil
        )

        _ = try await adapter.sendBatch([Self.batchItem(#"{"i":1}"#)])

        let sent = try #require(recorder.sent.first)
        #expect(sent.headers["Authorization"] == nil)
    }

    // MARK: per-item result cardinality + ordering

    @Test(
        "sendBatch returns exactly one Result per input item",
        .tags(.axm4)
    )
    func sendBatchReturnsOneResultPerInputItem() async throws {
        let recorder = RecordingAxiomIngestTransport()
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = (1 ... 7).map { Self.batchItem(#"{"i":\#($0)}"#) }

        let results = try await adapter.sendBatch(items)

        #expect(results.count == items.count)
    }

    @Test(
        "2xx Axiom response resolves every input item to .success",
        .tags(.axm6)
    )
    func twoXXAllSuccess() async throws {
        let recorder = RecordingAxiomIngestTransport()
        recorder.setResponseBody(Data(#"{"ingested":3,"failed":0}"#.utf8))
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = (1 ... 3).map { Self.batchItem(#"{"i":\#($0)}"#) }

        let results = try await adapter.sendBatch(items)

        #expect(results.count == 3)
        for result in results {
            switch result {
            case .success: break
            case .failure: Issue.record("expected .success for 2xx response")
            }
        }
    }

    @Test(
        "Input ordering is preserved in the JSON array request body",
        .tags(.axm5)
    )
    func inputOrderingPreservedInRequestBody() async throws {
        let recorder = RecordingAxiomIngestTransport()
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = [
            Self.batchItem(#"{"i":1}"#),
            Self.batchItem(#"{"i":2}"#),
            Self.batchItem(#"{"i":3}"#)
        ]

        _ = try await adapter.sendBatch(items)

        let sent = try #require(recorder.sent.first)
        let expected = Data(#"[{"i":1},{"i":2},{"i":3}]"#.utf8)
        #expect(sent.body == expected)
    }

    // MARK: classify -- HTTP status code mapping

    @Test(
        "classify: 408 -> .retryable",
        .tags(.axm8)
    )
    func classify408Retryable() {
        let outcome = AxiomRemoteTransport.classify(
            error: AxiomIngestTransportError.unsuccessfulStatus(408)
        )
        #expect(outcome == .retryable(reason: .transportRejected))
    }

    @Test(
        "classify: 429 -> .retryable",
        .tags(.axm8)
    )
    func classify429Retryable() {
        let outcome = AxiomRemoteTransport.classify(
            error: AxiomIngestTransportError.unsuccessfulStatus(429)
        )
        #expect(outcome == .retryable(reason: .transportRejected))
    }

    @Test(
        "classify: 5xx -> .retryable",
        .tags(.axm8)
    )
    func classify5xxRetryable() {
        for status in [500, 502, 503, 504, 599] {
            let outcome = AxiomRemoteTransport.classify(
                error: AxiomIngestTransportError.unsuccessfulStatus(status)
            )
            #expect(
                outcome == .retryable(reason: .transportRejected),
                "expected .retryable for status \(status)"
            )
        }
    }

    @Test(
        "classify: 401 -> .terminal",
        .tags(.axm9)
    )
    func classify401Terminal() {
        let outcome = AxiomRemoteTransport.classify(
            error: AxiomIngestTransportError.unsuccessfulStatus(401)
        )
        #expect(outcome == .terminal(reason: .transportRejected))
    }

    @Test(
        "classify: 403 -> .terminal",
        .tags(.axm9)
    )
    func classify403Terminal() {
        let outcome = AxiomRemoteTransport.classify(
            error: AxiomIngestTransportError.unsuccessfulStatus(403)
        )
        #expect(outcome == .terminal(reason: .transportRejected))
    }

    @Test(
        "classify: 400 (other 4xx, neither 408 nor 429) -> .terminal",
        .tags(.axm9)
    )
    func classify400Terminal() {
        for status in [400, 404, 405, 409, 422] {
            let outcome = AxiomRemoteTransport.classify(
                error: AxiomIngestTransportError.unsuccessfulStatus(status)
            )
            #expect(
                outcome == .terminal(reason: .transportRejected),
                "expected .terminal for status \(status)"
            )
        }
    }

    @Test(
        "classify: invalidResponse -> .retryable",
        .tags(.axm8)
    )
    func classifyInvalidResponseRetryable() {
        let outcome = AxiomRemoteTransport.classify(
            error: AxiomIngestTransportError.invalidResponse
        )
        #expect(outcome == .retryable(reason: .transportRejected))
    }

    @Test(
        "classify: arbitrary network error -> .retryable",
        .tags(.axm8)
    )
    func classifyArbitraryErrorRetryable() {
        struct NetworkErrorStub: Error {}
        let outcome = AxiomRemoteTransport.classify(error: NetworkErrorStub())
        #expect(outcome == .retryable(reason: .transportRejected))
    }

    @Test(
        "classify: 3xx unknown status -> .retryable (fail-safe default)",
        .tags(.axm8)
    )
    func classifyUnknownStatusRetryable() {
        let outcome = AxiomRemoteTransport.classify(
            error: AxiomIngestTransportError.unsuccessfulStatus(304)
        )
        #expect(outcome == .retryable(reason: .transportRejected))
    }

    // MARK: classify(_:) async surface

    @Test(
        "classify(.success(_)) -> .success",
        .tags(.axm10)
    )
    func classifySuccess() async {
        let recorder = RecordingAxiomIngestTransport()
        let adapter = try? Self.makeDirectAdapter(transport: recorder)
        let outcome = await adapter?.classify(
            .success(RemoteTransportResponse(responseBytes: Data()))
        )
        #expect(outcome == .success)
    }

    @Test(
        "Whole-batch throw resolves every item via classify(.failure(error))",
        .tags(.axm7)
    )
    func wholeBatchThrowProjectsThroughClassify() async throws {
        let recorder = RecordingAxiomIngestTransport()
        recorder.setErrors([AxiomIngestTransportError.unsuccessfulStatus(503)])
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = (1 ... 3).map { Self.batchItem(#"{"i":\#($0)}"#) }

        await #expect(
            throws: AxiomIngestTransportError.unsuccessfulStatus(503),
            performing: { _ = try await adapter.sendBatch(items) }
        )

        // AXM-7 contract: the engine routes the whole-batch throw
        // through `classify(.failure(error))` for every active item.
        // Assert the per-item projection explicitly so the coverage
        // tag proves failure projection through the classifier, not
        // just that `sendBatch` threw.
        for _ in items {
            let outcome = await adapter.classify(
                .failure(AxiomIngestTransportError.unsuccessfulStatus(503))
            )
            #expect(outcome == .retryable(reason: .transportRejected))
        }
    }
}
