import Foundation
import LoggerRemote

/// `RemoteTransport` adapter that bridges `swift-logger-remote`'s
/// durable delivery engine to Axiom's HTTP ingest endpoint.
///
/// The adapter is **batch-aggregating**: every non-empty
/// ``RemoteTransport/sendBatch(_:)`` call builds **one** Axiom HTTP
/// request carrying every input item, POSTs it through the injected
/// ``AxiomIngestTransport`` seam, and projects the result back into
/// one `Result<RemoteTransportResponse, any Error>` per input item
/// in the same order as the input batch. An empty `items` array
/// returns `[]` and dispatches no Axiom request. The remote engine
/// owns the durable queue, retry budget, batch rounds,
/// retained-artifact reuse, and acknowledgement-to-removal
/// lifecycle; the adapter stores only endpoint configuration and the
/// injected ingest transport handle.
///
/// ## Axiom response model
///
/// Axiom's ingest endpoint returns a **whole-request** status code
/// and a single `{"ingested": N, "failed": M, "failures": [...]}`-
/// shaped envelope. This adapter does **not** semantically parse or
/// validate the response body and does **not** inspect the
/// `failures` array, so a 2xx ingest reply is the success signal for
/// every active item in the batch round; per-item results all
/// succeed with identical opaque response bytes for the batch round.
/// Whole-request failures throw from ``sendBatch(_:)`` so the engine
/// routes the same failure through ``classify(_:)`` for every active
/// item in the batch round.
///
/// ## Ownership boundaries
///
/// `swift-logger-axiom` owns:
/// - Axiom request framing from the ordered host-encoded event
///   payload bytes provided by the engine (one JSON array body per
///   batch round, with one Axiom event document per array element).
/// - Axiom response classification by HTTP status code.
///
/// `swift-logger-remote` owns:
/// - The durable queue (`DurableRemoteQueue`).
/// - The retry budget and the batch-round dispatcher.
/// - The acknowledgement-to-removal lifecycle (no destructive
///   removal until the engine acknowledges a fully-resolved
///   non-empty flush pass).
/// - The retained export artifact and outstanding-batch reuse on
///   retryable continuations.
///
/// The adapter never re-implements those concerns; it would
/// duplicate state the engine already owns.
struct AxiomRemoteTransport: RemoteTransport {
    /// Target Axiom endpoint (direct ingest or intake gateway). Both
    /// cases are POSTed verbatim; the adapter does not guess or
    /// mutate the URL path.
    let endpoint: AxiomEndpoint

    /// HTTP client seam used to dispatch the Axiom ingest request.
    /// The `URLSession`-backed initializer wires this to
    /// ``URLSessionAxiomIngestTransport``; the seam-injecting
    /// initializer takes a custom transport so tests can record
    /// without touching the network.
    private let transport: any AxiomIngestTransport

    /// Constructs an adapter that dispatches every Axiom ingest
    /// request through `URLSession`. The session defaults to
    /// `.shared` so callers can plug in a custom configuration (for
    /// example a per-process session with a tighter timeout) by
    /// injecting their own `URLSession`.
    init(
        endpoint: AxiomEndpoint,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        transport = URLSessionAxiomIngestTransport(session: urlSession)
    }

    /// Test-only initializer that swaps the HTTP seam for a custom
    /// ``AxiomIngestTransport`` implementation. Marked `internal`
    /// because ``AxiomIngestTransport`` is the package-internal
    /// transport contract; the public surface only exposes the
    /// `URLSession`-backed shape.
    init(
        endpoint: AxiomEndpoint,
        transport: any AxiomIngestTransport
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    /// Dispatches the input batch as one Axiom ingest request and
    /// returns one `Result` per input item in input order.
    ///
    /// **Whole-request success.** Axiom's ingest endpoint returns a
    /// single 2xx status for the entire request and the adapter has
    /// no per-event result surface to consult (the `failures` array
    /// in the response body is intentionally not parsed in
    /// `0.1.0`), so every input item resolves to `.success` carrying
    /// the opaque response bytes Axiom returned.
    ///
    /// **Whole-request failure routing.** Anything that prevents the
    /// Axiom request from completing with a valid 2xx transport
    /// response -- non-2xx status, network error, transport-level
    /// response-shape failure -- throws from `sendBatch`. The engine
    /// treats the throw as a transport-level failure for every
    /// active item in the batch round and runs each item through
    /// ``classify(_:)`` with `.failure(error)`.
    func sendBatch(
        _ items: [RemoteTransportBatchItem]
    ) async throws -> [Result<RemoteTransportResponse, any Error>] {
        // Empty active set: skip the Axiom round-trip. Sending an
        // empty JSON-array body would be a spurious request and
        // there is nothing to project per-item against.
        guard !items.isEmpty else {
            return []
        }

        let body = AxiomIngestRequestBody.make(events: items.map(\.payloadBytes))

        var headers = ["Content-Type": "application/json"]
        if let authorization = endpoint.authorizationHeaderValue {
            headers["Authorization"] = authorization
        }

        // HTTP non-2xx, network, TLS, and DNS failures throw from
        // the AxiomIngestTransport seam. We let those propagate so
        // the engine routes the whole batch through `classify(_:)`.
        let responseBody = try await transport.send(
            url: endpoint.requestURL,
            headers: headers,
            body: body
        )

        // Axiom's ingest endpoint reports per-event failures inside
        // the response body's `failures` array, but `0.1.0` does
        // not parse the body for per-item classification, so a 2xx
        // response is the success signal for every input item.
        let response = RemoteTransportResponse(responseBytes: responseBody)
        return items.map { _ in .success(response) }
    }

    /// Maps a per-item `Result` from ``sendBatch(_:)`` (or a
    /// whole-batch `.failure(error)` raised by a `sendBatch` throw)
    /// into a `RemoteDeliveryResult` the engine consumes.
    ///
    /// **Sink-owned.** The engine never inspects HTTP status or
    /// transport error types; the mapping below is the adapter's
    /// authoritative rule:
    ///
    /// - `.success(_)` -> `.success`.
    /// - `.failure(AxiomIngestTransportError.unsuccessfulStatus(s))`
    ///   where `s == 408 || s == 429 || (500..<600).contains(s)`
    ///   -> `.retryable` (transient: request-timeout, ingest
    ///   backpressure, or server-side failure that may clear on
    ///   retry).
    /// - `.failure(AxiomIngestTransportError.unsuccessfulStatus(s))`
    ///   where `(400..<500).contains(s)` and `s` is none of the
    ///   above -> `.terminal` (401 / 403 invalid or disabled token,
    ///   400 malformed body or schema violation -- retrying with the
    ///   same request shape and credentials will not help).
    /// - `.failure(AxiomIngestTransportError.invalidResponse)` ->
    ///   `.retryable` (usually transient proxy / TLS / connection
    ///   issue rather than permanent endpoint misconfiguration).
    /// - Any other `.failure(_)` (URLError, DNS, TLS, cancellation,
    ///   ...) -> `.retryable`.
    func classify(
        _ result: Result<RemoteTransportResponse, any Error>
    ) async -> RemoteDeliveryResult {
        switch result {
        case .success:
            return .success
        case let .failure(error):
            return Self.classify(error: error)
        }
    }

    /// Pure classification of an error value without mutating queue
    /// acknowledgement, export-file lifecycle, or retry lifecycle
    /// state. Split from ``classify(_:)`` so the test target can
    /// exercise the mapping table without constructing
    /// `Result.failure` wrappers per case.
    static func classify(error: any Error) -> RemoteDeliveryResult {
        if let transportError = error as? AxiomIngestTransportError {
            switch transportError {
            case let .unsuccessfulStatus(status):
                if status == 408 || status == 429 || (500 ..< 600).contains(status) {
                    return .retryable(reason: .transportRejected)
                }
                if (400 ..< 500).contains(status) {
                    // Permanent rejection: auth failure (401 / 403),
                    // malformed request (400 invalid JSON / schema
                    // violation), or unknown dataset (404) --
                    // retrying with the same request shape and
                    // credentials will not help.
                    return .terminal(reason: .transportRejected)
                }
                // 3xx, 1xx, or unusual status codes outside the
                // documented Axiom ingest surface -- treat as
                // transient until the integration's actual semantics
                // are established. The default for an unexpected
                // HTTP status class is retryable rather than
                // terminal for forward compatibility, so a
                // transient gateway redirect or informational
                // status does not silently discard delivered bytes.
                return .retryable(reason: .transportRejected)
            case .invalidResponse:
                return .retryable(reason: .transportRejected)
            }
        }
        return .retryable(reason: .transportRejected)
    }
}
