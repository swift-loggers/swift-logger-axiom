import Foundation

/// Internal HTTP seam used by the ``AxiomRemoteTransport`` adapter
/// that bridges Axiom HTTP ingest delivery onto
/// `swift-logger-remote`'s durable engine.
///
/// Callers produce the URL, headers, and body for one HTTP request
/// (the framed JSON array body for an entire batch of events); the
/// seam is responsible for the network round-trip and for returning
/// the response body so the adapter can decide whole-batch
/// classification.
///
/// `AxiomIngestTransport` is **not** public API. The production
/// implementation is ``URLSessionAxiomIngestTransport``; tests inject
/// a recorder that captures the request without touching the
/// network. The package exposes durable delivery through the
/// ``AxiomRemoteEngine/make(_:)`` factory, and neither path requires
/// the caller to wire an `AxiomIngestTransport` directly.
protocol AxiomIngestTransport: Sendable {
    /// Sends `body` as the HTTP body of a POST request to `url` with
    /// the supplied `headers`. Implementations should throw for
    /// transport-level request failures and non-2xx HTTP responses.
    ///
    /// - Returns: The response body. Empty when the server returns
    ///   no body; never `nil`.
    func send(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> Data
}

/// Errors the default ``URLSessionAxiomIngestTransport`` raises when
/// the remote endpoint rejects an Axiom ingest payload. The
/// conformance to ``Equatable`` lets tests pin specific cases via
/// `#expect(throws: AxiomIngestTransportError.<case>)` rather than
/// the looser `#expect(throws: AxiomIngestTransportError.self)`.
enum AxiomIngestTransportError: Error, Sendable, Equatable {
    /// The HTTP response returned a non-2xx status code. Classified
    /// by ``AxiomRemoteTransport`` per
    /// ``AxiomRemoteTransport/classify(_:)``: 408, 429, and 5xx map
    /// to retryable; 401, 403, and other 4xx map to terminal.
    case unsuccessfulStatus(Int)

    /// The HTTP response was missing or could not be inspected as an
    /// `HTTPURLResponse`. ``AxiomRemoteTransport/classify(_:)``
    /// treats this as retryable because it usually reflects a
    /// transient proxy / TLS / connection issue rather than a
    /// permanent endpoint misconfiguration.
    case invalidResponse
}

/// Production transport that POSTs the framed Axiom ingest body
/// through `URLSession`. Treated as `@unchecked Sendable` because
/// `URLSession` is documented thread-safe and is held immutably
/// here even though Foundation does not declare formal Sendable
/// conformance on the iOS 13 deployment target.
struct URLSessionAxiomIngestTransport: AxiomIngestTransport, @unchecked Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        let (responseBody, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AxiomIngestTransportError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw AxiomIngestTransportError.unsuccessfulStatus(http.statusCode)
        }
        return responseBody
    }
}
