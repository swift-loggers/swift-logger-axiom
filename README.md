# swift-logger-axiom

Axiom HTTP ingest adapter for
[`swift-loggers`](https://github.com/swift-loggers), built on top of
[`swift-loggers/swift-logger-remote`](https://github.com/swift-loggers/swift-logger-remote).

`swift-logger-axiom` is a concrete remote adapter on top of
`swift-logger-remote 0.1.0`. The package is durable-only: it
bridges Axiom HTTP ingest delivery onto the shared `RemoteEngine`
+ `DurableRemoteQueue` lifecycle without shipping a best-effort
in-memory logger of its own.

`AxiomRemoteEngine` bridges ingest delivery onto
`swift-logger-remote`'s durable engine: a persistence-backed
`DurableRemoteQueue`, a batch-round retry budget over the
`RemoteTransport.sendBatch(_:)` primitive, a caller-driven
`flush()` lifecycle, retained export reuse across flush passes,
and the acknowledgement-to-removal lifecycle (no destructive
removal until the engine acknowledges a fully-resolved non-empty
flush pass). The internal Axiom transport builds **one Axiom
request per non-empty dispatched batch round** (N events in one
HTTP request, framed as a JSON array with one Axiom event document
per array element), treats a 2xx Axiom reply as success for every
active item in the batch round, and projects whole-request
failures through `RemoteTransport.classify(_:)` for every active
item in the batch round. The host wires `flush()` from its own
lifecycle hooks (background notifications, shutdown signals,
periodic tasks).

> **`0.1.0` public API surface (final, locked):**
>
> - `AxiomRemoteEngine.make(_:)` -- the durable path. Returns a
>   `Wiring` carrying `DurableRemoteQueue` and `RemoteEngine`.
>   `Configuration` accepts `endpoint`, `queueDirectory`,
>   `exportDirectory`, `RemoteBatchPolicy`, `RemoteRetryPolicy`,
>   and an optional `URLSession` (defaults to `.shared`).
> - `AxiomEndpoint`: direct Axiom ingest with an Axiom API token,
>   or a consumer-owned intake / proxy / gateway endpoint with an
>   arbitrary `Authorization` header (or none).

Requires Swift 6.0+. iOS 13.4, macOS 10.15.4, tvOS 13.4,
watchOS 6.2, visionOS 1. MIT licensed.

API reference (DocC):
[swift-loggers.github.io/swift-logger-axiom](https://swift-loggers.github.io/swift-logger-axiom/documentation/loggeraxiom/).

## Threat model

`swift-logger-axiom` ships two `AxiomEndpoint` cases. Pick the
one that matches your trust model.

### `.axiom(url:token:)` -- direct delivery, informed opt-in

Direct mode POSTs to `url` verbatim with
`Authorization: Bearer <token>`. The adapter does **not** guess or
mutate the URL path: pass the full dataset-scoped ingest URL
(typically `https://api.axiom.co/v1/datasets/<dataset>/ingest`, or
the equivalent on a regional Axiom Cloud deployment such as
`https://api.eu.axiom.co/v1/datasets/<dataset>/ingest`) so the
adapter never silently targets a different endpoint than the
operator authorized.

This is a **supported informed opt-in**, not a prohibition. An
Axiom API token compiled into a client app binary is
**extractable** even when the app uses TLS: HTTPS protects the
network hop, not secrets embedded in the binary. Anyone with the
binary can recover the token with standard reverse-engineering
tooling, and the Axiom dataset behind that token inherits the
trust level of the distribution channel.

Direct mode is appropriate for trial setups, smoke tests against
Axiom Cloud, internal-only apps, prototypes, throwaway
exploration, and any context where the operator has consciously
accepted that risk. It is **not** the recommended shape for an
iOS or macOS app on the public App Store -- use `.intake(...)`
instead.

### `.intake(url:authorizationHeader:)` -- consumer-owned proxy / gateway

Intake mode POSTs to `url` verbatim (no path mutation) and sends
the consumer-supplied `Authorization` header value through
unchanged. Bearer, Basic, custom gateway tokens, or no auth are
supported through `.intake(url:authorizationHeader:)` because the
intake endpoint is consumer-owned. This is the recommended
hardened-production shape.

```
mobile / desktop client            first-party intake             Axiom ingest
-------------------------          ------------------             ------------
AxiomRemoteEngine.flush()    -->   your service              -->  dataset
  POST intake endpoint               - terminates client TLS         - real Axiom API token,
  JSON array body                    - authenticates the app           server-side
                                     - rate-limits / authorizes
                                     - forwards as Axiom ingest
                                     - holds the real credential
```

The intake service owns authentication, dataset routing, rate
limiting, schema evolution, and duplicate-suppression policy. The
mobile client only needs to reach the intake URL; the Axiom API
token that talks to Axiom never has to leave the server.

If you control the entire trust boundary (for example, a back-end
Swift service running inside the same VPC as a private Axiom
deployment), pick whichever case matches what you actually
configured: `.axiom` if the URL is the Axiom ingest endpoint and
you set the API token; `.intake` with `authorizationHeader: nil`
if the URL is your in-VPC sidecar that authenticates by network
position.

## Installation

Add this package, the core
[`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger)
package (`LoggerLibrary`), and
[`swift-loggers/swift-logger-remote`](https://github.com/swift-loggers/swift-logger-remote)
to your `Package.swift`. All three release-lock to `0.1.0` through
SwiftPM's `.upToNextMinor(from: "0.1.0")` requirement. The `LoggerLibrary`
product re-exports the core abstractions and the companion adapters
and is the recommended import for consumer code.

```swift
// In your Package.swift:
let package = Package(
    name: "MyApp",
    dependencies: [
        .package(
            url: "https://github.com/swift-loggers/swift-logger-axiom.git",
            .upToNextMinor(from: "0.1.0")
        ),
        .package(
            url: "https://github.com/swift-loggers/swift-logger.git",
            .upToNextMinor(from: "0.1.0")
        ),
        .package(
            url: "https://github.com/swift-loggers/swift-logger-remote.git",
            .upToNextMinor(from: "0.1.0")
        )
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "LoggerAxiom", package: "swift-logger-axiom"),
                .product(name: "LoggerLibrary", package: "swift-logger"),
                .product(name: "LoggerRemote", package: "swift-logger-remote")
            ]
        )
    ]
)
```

## Durable delivery with `AxiomRemoteEngine`

`AxiomRemoteEngine.make(_:)` returns a `Wiring` carrying a
`DurableRemoteQueue` and a `RemoteEngine` from
`swift-logger-remote`. Hosts enqueue pre-encoded Axiom event
documents onto the queue and call `engine.flush()` from their own
lifecycle hooks; the engine drives batch rounds against the
internal Axiom transport, applies the configured retry budget,
and acknowledges (removes delivered queue payload bytes) only
when every recovered entry across the pass resolves as `.success`
or `.terminal`.

**Payload contract.** `DurableRemoteQueue.enqueue(_:)` admits a
`RemoteDeliveryEntry` whose `payload` is **opaque pre-encoded
bytes**. For this Axiom wiring those bytes are one **event
document** -- a complete JSON value that Axiom indexes as a single
ingest event (typically a JSON object).

Neither the engine nor the internal Axiom transport encodes
upstream log records on the caller's behalf. The transport's only
payload responsibility is to frame the batch's events into one
JSON array:

    [<event_1>,<event_2>,...,<event_n>]

The adapter does **not** wrap events in a per-event metadata
envelope; Axiom indexes each array element as a single ingest
event using the host-provided JSON value verbatim.

### Recommended: intake / proxy mode

```swift
import Foundation
import LoggerRemote
import LoggerAxiom

let queueDirectory = URL(fileURLWithPath: "/tmp/swift-logger-axiom/queue")
let exportDirectory = URL(fileURLWithPath: "/tmp/swift-logger-axiom/exports")

let configuration = AxiomRemoteEngine.Configuration(
    endpoint: .intake(
        url: URL(string: "https://logs.example.com/axiom")!,
        authorizationHeader: "Bearer demo-app-token"
    ),
    queueDirectory: queueDirectory,
    exportDirectory: exportDirectory,
    batchPolicy: try RemoteBatchPolicy.make(
        maxEntryCount: 100,
        maxByteCount: 64 * 1024
    ),
    retryPolicy: try RemoteRetryPolicy.make(
        maxAttempts: 3,
        backoff: .exponential(
            initialSeconds: 0.5, multiplier: 2, capSeconds: 8
        )
    )
)
let wiring = AxiomRemoteEngine.make(configuration)

let eventBytes = try JSONSerialization.data(
    withJSONObject: ["message": "hello, axiom", "level": "info"]
)
try await wiring.queue.enqueue(RemoteDeliveryEntry(
    identifier: 1,
    payload: eventBytes
))
_ = try await wiring.engine.flush()
```

### Direct Axiom mode (trial / smoke / internal)

```swift
import Foundation
import LoggerRemote
import LoggerAxiom

let queueDirectory = URL(fileURLWithPath: "/tmp/swift-logger-axiom/queue")
let exportDirectory = URL(fileURLWithPath: "/tmp/swift-logger-axiom/exports")
let apiToken = "your-axiom-api-token"

let directConfiguration = AxiomRemoteEngine.Configuration(
    endpoint: .axiom(
        url: URL(string: "https://api.axiom.co/v1/datasets/demo/ingest")!,
        token: apiToken
    ),
    queueDirectory: queueDirectory,
    exportDirectory: exportDirectory,
    batchPolicy: try RemoteBatchPolicy.make(
        maxEntryCount: 100, maxByteCount: 64 * 1024
    ),
    retryPolicy: try RemoteRetryPolicy.make(
        maxAttempts: 3,
        backoff: .exponential(
            initialSeconds: 0.5, multiplier: 2, capSeconds: 8
        )
    )
)
let directWiring = AxiomRemoteEngine.make(directConfiguration)
_ = directWiring
```

The adapter sends to the configured URL verbatim with
`Authorization: Bearer <token>`. Read the threat-model note above
before shipping a binary that contains an Axiom API token.

### Custom URLSession

`AxiomRemoteEngine.Configuration` accepts an optional
`urlSession: URLSession` parameter (defaults to
`URLSession.shared`) so consumers can hand the adapter a
pre-configured session without subclassing or swapping the
transport. Pass a custom `URLSession` when the deployment requires
certificate pinning, mTLS, enterprise proxy configuration, custom
trust handling, or a controlled timeout policy. The session only
controls the underlying network round-trip; it does not influence
retry, batching, or acknowledgement, which stay owned by
`swift-logger-remote`'s engine.

## Response model

Axiom's ingest endpoint returns a **whole-request** status code
and a single `{"ingested": N, "failed": M, "failures": [...]}`-
shaped envelope. `swift-logger-axiom 0.1.0` does **not**
semantically parse or validate the response body for per-item
classification, so:

- A 2xx Axiom reply resolves every active item in the batch round
  to `.success` with the opaque response bytes Axiom returned.
- HTTP 408 (request timeout), 429 (rate-limited), 5xx (server
  error), network / DNS / TLS / timeout / invalid-response
  transport failures, and unexpected HTTP status classes classify
  as **retryable** for forward compatibility.
- HTTP 401 (unauthorized), 403 (forbidden / token lacks dataset
  permission), and other 4xx (400 malformed JSON / schema
  violation / unknown dataset, 404, 405, 409, 422, ...) classify
  as **terminal**.

## Non-goals

`swift-logger-axiom 0.1.0` deliberately ships no:

- best-effort in-memory `AxiomLogger`; the package intentionally
  focuses on the durable remote path only.
- autonomous scheduler (`flush()` is caller-driven).
- platform lifecycle observer (host code wires `flush()` from
  whatever lifecycle hooks it cares about).
- SDK / RUM integration (`swift-logger-axiom` is HTTP-only; Axiom
  does not ship a first-party iOS SDK).
- per-item parsing of Axiom's `failures` response array; whole-
  batch 2xx -> success projection is the `0.1.0` contract.
- query / search API (this package writes events; reading is out
  of scope).
- direct mobile-safe token claims (the Axiom API token is
  extractable from any client binary that holds it; use
  `.intake(...)` for hardened production deployments).

## License

MIT. See [LICENSE](LICENSE).
