import Foundation

/// The destination an ``AxiomRemoteEngine`` POSTs Axiom HTTP ingest
/// payloads to, plus the credentials needed to reach it.
///
/// `AxiomEndpoint` has two cases that correspond to two distinct
/// deployment shapes; pick the one that matches your trust model.
///
/// ## ``AxiomEndpoint/axiom(url:token:)``
///
/// Direct delivery to Axiom's HTTP ingest API. The adapter POSTs the
/// JSON array request body to `url` **verbatim** -- it does not
/// guess or mutate the URL path -- and sends the configured Axiom
/// API token in an `Authorization: Bearer <token>` header on every
/// request. Pass the full dataset-scoped ingest URL (typically
/// `https://api.axiom.co/v1/datasets/<dataset>/ingest`, or the
/// equivalent on a regional Axiom Cloud deployment such as
/// `https://api.eu.axiom.co/v1/datasets/<dataset>/ingest`) so the
/// adapter never silently picks an endpoint path you did not
/// authorize.
///
/// This mode is a supported, informed opt-in. **An Axiom API token
/// compiled into a client app binary is extractable**: anyone with
/// the binary can recover the token with standard reverse-engineering
/// tooling, so the Axiom dataset behind that token inherits the
/// trust level of the distribution channel. Direct mode is
/// appropriate for trial setups, smoke tests, internal-only apps,
/// prototypes, and any context where the operator has consciously
/// accepted that risk. For hardened production use cases the
/// recommended shape is ``intake(url:authorizationHeader:)`` (or
/// another intermediary you control), so the real Axiom API token
/// never ships with the client.
///
/// ## ``AxiomEndpoint/intake(url:authorizationHeader:)``
///
/// Delivery through a first-party intake / proxy / gateway endpoint
/// owned by the consumer. The adapter POSTs the JSON array request
/// body to `url` verbatim and lets the intake decide its own URL
/// conventions, dataset routing, rate limiting, and onward
/// forwarding to Axiom.
///
/// `authorizationHeader` is sent verbatim as the value of the
/// `Authorization` request header. Bearer, Basic, custom gateway
/// tokens, or no auth are supported through this case because the
/// intake endpoint is consumer-owned. Pass `nil` to omit the
/// `Authorization` header entirely (for example, when the intake
/// runs on a private network and authenticates by transport-level
/// trust).
public enum AxiomEndpoint: Sendable, Equatable {
    /// Direct delivery to Axiom's HTTP ingest API using an Axiom API
    /// token credential.
    ///
    /// - Parameters:
    ///   - url: The full dataset-scoped ingest URL. The adapter POSTs
    ///     to this URL verbatim and does not append or mutate the
    ///     path; on Axiom Cloud this is typically
    ///     `https://api.axiom.co/v1/datasets/<dataset>/ingest`.
    ///   - token: The Axiom API token. Sent as
    ///     `Authorization: Bearer <token>` verbatim. Treat this
    ///     value as extractable when compiled into a client binary.
    case axiom(url: URL, token: String)

    /// Delivery through a consumer-owned intake / proxy / gateway
    /// endpoint.
    ///
    /// - Parameters:
    ///   - url: The intake URL. The adapter sends to this URL
    ///     verbatim and does not mutate the path.
    ///   - authorizationHeader: The full value of the
    ///     `Authorization` header (for example `"Bearer abc"` or
    ///     `"Basic dXNlcjpwYXNz"`), or `nil` to omit the header
    ///     entirely.
    case intake(url: URL, authorizationHeader: String?)
}

extension AxiomEndpoint {
    /// The URL the adapter POSTs JSON array bodies to. Both cases
    /// return the configured URL verbatim; the adapter never
    /// guesses or rewrites the path so a misconfigured base URL
    /// fails closed at the network round-trip instead of silently
    /// targeting a different endpoint than the caller expected.
    var requestURL: URL {
        switch self {
        case let .axiom(url, _):
            return url
        case let .intake(url, _):
            return url
        }
    }

    /// The value the adapter sends in the `Authorization` request
    /// header, or `nil` to omit the header. Direct mode produces
    /// `"Bearer <token>"`; intake mode passes the consumer's header
    /// value through verbatim.
    var authorizationHeaderValue: String? {
        switch self {
        case let .axiom(_, token):
            return "Bearer \(token)"
        case let .intake(_, header):
            return header
        }
    }
}
