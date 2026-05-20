import Foundation
import Testing

@testable import LoggerAxiom

@Suite("AxiomEndpoint")
struct AxiomEndpointTests {
    // MARK: requestURL

    @Test(
        "Direct Axiom endpoint preserves the URL verbatim and never appends a path",
        .tags(.axm11)
    )
    func axiomRequestURLIsVerbatim() throws {
        let url = try #require(URL(string: "https://api.axiom.co/v1/datasets/demo/ingest"))
        let endpoint = AxiomEndpoint.axiom(url: url, token: "tok")

        #expect(endpoint.requestURL == url)
    }

    @Test(
        "Intake endpoint preserves the URL verbatim",
        .tags(.axm12)
    )
    func intakeRequestURLIsVerbatim() throws {
        let url = try #require(URL(string: "https://logs.example.com/axiom"))
        let endpoint = AxiomEndpoint.intake(
            url: url,
            authorizationHeader: "Bearer abc"
        )

        #expect(endpoint.requestURL == url)
    }

    // MARK: authorizationHeaderValue

    @Test(
        "Direct Axiom endpoint produces a `Bearer <token>` Authorization value",
        .tags(.axm11)
    )
    func axiomAuthorizationHeader() throws {
        let url = try #require(URL(string: "https://api.axiom.co/v1/datasets/demo/ingest"))
        let endpoint = AxiomEndpoint.axiom(url: url, token: "xaat-abc123")

        #expect(endpoint.authorizationHeaderValue == "Bearer xaat-abc123")
    }

    @Test(
        "Intake endpoint passes the Authorization header through verbatim",
        .tags(.axm12)
    )
    func intakeAuthorizationHeaderPassthrough() throws {
        let url = try #require(URL(string: "https://logs.example.com"))

        let bearer = AxiomEndpoint.intake(
            url: url,
            authorizationHeader: "Bearer xyz"
        )
        #expect(bearer.authorizationHeaderValue == "Bearer xyz")

        let basic = AxiomEndpoint.intake(
            url: url,
            authorizationHeader: "Basic dXNlcjpwYXNz"
        )
        #expect(basic.authorizationHeaderValue == "Basic dXNlcjpwYXNz")

        let custom = AxiomEndpoint.intake(
            url: url,
            authorizationHeader: "X-Gateway tok-via-intake"
        )
        #expect(custom.authorizationHeaderValue == "X-Gateway tok-via-intake")
    }

    @Test(
        "Intake endpoint with nil header omits the Authorization header",
        .tags(.axm12)
    )
    func intakeNilAuthorizationOmitsHeader() throws {
        let url = try #require(URL(string: "https://logs.example.com"))
        let endpoint = AxiomEndpoint.intake(
            url: url,
            authorizationHeader: nil
        )

        #expect(endpoint.authorizationHeaderValue == nil)
    }

    // MARK: Equatable

    @Test("Equatable: same case + same associated values compare equal")
    func equatableSameCaseEqual() throws {
        let url = try #require(URL(string: "https://api.axiom.co/v1/datasets/demo/ingest"))
        let lhs = AxiomEndpoint.axiom(url: url, token: "tok")
        let rhs = AxiomEndpoint.axiom(url: url, token: "tok")

        #expect(lhs == rhs)
    }

    @Test("Equatable: different cases compare not-equal")
    func equatableCrossCaseNotEqual() throws {
        let url = try #require(URL(string: "https://api.axiom.co/v1/datasets/demo/ingest"))
        let direct = AxiomEndpoint.axiom(url: url, token: "tok")
        let intake = AxiomEndpoint.intake(url: url, authorizationHeader: "Bearer tok")

        #expect(direct != intake)
    }
}
