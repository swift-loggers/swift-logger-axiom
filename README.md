# swift-logger-axiom

Axiom HTTP ingest adapter for
[`swift-loggers`](https://github.com/swift-loggers), built on top of
[`swift-loggers/swift-logger-remote`](https://github.com/swift-loggers/swift-logger-remote).

`swift-logger-axiom` is a concrete remote adapter on top of
`swift-logger-remote 0.1.0`. The package bridges Axiom HTTP ingest
delivery onto the shared `RemoteEngine` + `DurableRemoteQueue`
lifecycle and ships a batteries-included `Loggers.Logger` adapter
(`AxiomLogger`) that admits log entries non-blockingly and routes
them through that engine.

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

> **`0.2.0` public API surface:**
>
> - `AxiomRemoteEngine.make(_:)` -- the durable path. Returns a
>   `Wiring` carrying `DurableRemoteQueue` and `RemoteEngine`.
>   `Configuration` accepts `endpoint`, `queueDirectory`,
>   `exportDirectory`, `RemoteBatchPolicy`, `RemoteRetryPolicy`,
>   and an optional `URLSession` (defaults to `.shared`).
> - `AxiomEndpoint`: direct Axiom ingest with an Axiom API token,
>   or a consumer-owned intake / proxy / gateway endpoint with an
>   arbitrary `Authorization` header (or none).
> - `AxiomLogger`: `Loggers.Logger` adapter with bounded admission
>   buffer, a single internal serial worker, a pluggable
>   `AxiomLogEventEncoder`, a pluggable `AxiomIdentifierProvider`,
>   buffer-policy and minimum-level controls, and an
>   `onDiagnostic` callback. `flush()` drains accepted pending
>   entries and runs the engine flush pass.
> - `AxiomLoggingService`: optional flush coordinator over an
>   `AxiomLogger`. `AxiomFlushPolicy` selects `.manual` or
>   `.periodic(seconds:)` cadence; `AxiomLoggingServiceDiagnostic`
>   surfaces `flushFailed(String)` and
>   `invalidFlushInterval(seconds:)`.

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
to your `Package.swift`. `swift-logger-axiom` release-locks to
`0.2.0`; the core and remote packages release-lock to `0.1.0`. The
`LoggerLibrary` product re-exports the core abstractions and the
companion adapters and is the recommended import for consumer
code.

```swift
// In your Package.swift:
let package = Package(
    name: "MyApp",
    dependencies: [
        .package(
            url: "https://github.com/swift-loggers/swift-logger-axiom.git",
            .upToNextMinor(from: "0.2.0")
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

## `AxiomLogger`

`AxiomLogger` is a batteries-included `Loggers.Logger` adapter that
wraps an `AxiomRemoteEngine.Wiring` with a bounded admission
buffer, a single internal serial worker, a default JSON event
encoder, and a default monotonic identifier provider. Call sites
log structured entries through the standard `Loggers.Logger`
contract; the worker materializes each accepted entry, encodes it,
and enqueues it onto the durable queue.

```swift
import Foundation
import LoggerRemote
import Loggers
import LoggerAxiom

let queueDirectory = URL(fileURLWithPath: "/tmp/swift-logger-axiom/queue")
let exportDirectory = URL(fileURLWithPath: "/tmp/swift-logger-axiom/exports")

let wiring = AxiomRemoteEngine.make(
    AxiomRemoteEngine.Configuration(
        endpoint: .intake(
            url: URL(string: "https://logs.example.com/axiom")!,
            authorizationHeader: "Bearer demo-app-token"
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
)

let logger = AxiomLogger(
    wiring: wiring,
    bufferPolicy: .dropOldest(capacity: 2_000),
    minimumLevel: .info,
    onDiagnostic: { diagnostic in
        // Surface admission drops, encoding failures, identifier
        // failures, and queue enqueue failures to your own
        // observability stack.
        print("axiom diagnostic: \(diagnostic)")
    }
)

let network: LoggerDomain = "Network"
logger.info(network, "Request finished", attributes: [
    LogAttribute("status", 200),
    LogAttribute("path", "/api/items"),
    LogAttribute("user_id", "alice", privacy: .private)
])
let summary = try await logger.flush()
```

**Admission.** `log(_:_:_:attributes:)` is synchronous and
non-blocking with respect to the durable queue. The drop guard for
`LoggerLevel.disabled` and below-minimum entries runs at the call
site **before** the `message` or `attributes` autoclosures are
evaluated, so dropped entries never pay the cost of building their
payload. When the bounded buffer is full,
`.dropNewest(capacity:)` rejects the new entry without evaluating
its closures and `.dropOldest(capacity:)` evicts the oldest
pending entry (also without evaluating it) and admits the new
entry. Buffer drops fire `AxiomLoggerDiagnostic.bufferFull(dropped:)`.

**Worker.** A single internal serial worker materializes each
accepted entry, evaluates its `message` and `attributes`
autoclosures exactly once, calls the configured
`AxiomLogEventEncoder`, allocates an identifier through the
configured `AxiomIdentifierProvider`, and enqueues the payload
bytes onto the durable queue. Encoder, identifier, and queue
enqueue failures surface as `encodingFailed`, `identifierFailed`,
and `enqueueFailed` diagnostics; the logger does not locally retry the
entry. The worker is implementation-private and not actor-isolated
API surface.

**Flush.** An accepted pending entry is a log entry successfully
admitted into `AxiomLogger`'s internal buffer. `AxiomLogger.flush()`
returns to the caller only after every entry already admitted at the
moment of the call has either been enqueued or surfaced a diagnostic
failure, and then runs the engine flush pass. Entries dropped at
admission and entries admitted after `flush()` was invoked are not
part of the barrier.

### Default JSON event schema

`AxiomDefaultLogEventEncoder` emits one JSON object per event:

```json
{
  "_time": "2026-05-20T12:34:56.789Z",
  "level": "info",
  "domain": "Network",
  "message": "Request finished",
  "attributes": {
    "status": 200,
    "path": "/api/items",
    "user_id": "<private>"
  }
}
```

`_time` is an RFC 3339 wall-clock string with fractional-second
precision (`yyyy-MM-ddTHH:mm:ss.SSSZ`), always in UTC. Private
message segments and attribute values render as the literal string
`<private>`; sensitive ones render as `<redacted>`. Duplicate
attribute keys resolve last-wins. Non-finite `Double` attribute
values render through the stable string fallback
(`String(describing: value)`). The default encoder never throws for
representable logger events; unsupported attribute values are encoded
through the stable fallback path.

Consumers that need a custom Axiom dataset schema can supply their
own `AxiomLogEventEncoder`; consumers that need persistent
deduplication identity across app launches can supply their own
`AxiomIdentifierProvider`. `AxiomMonotonicIdentifierProvider` is
process-local and does not guarantee stable IDs across app restarts.

## `AxiomLoggingService`

`AxiomLoggingService` is an optional convenience over explicit
`AxiomLogger.flush()`. It owns scheduling (periodic flushes plus a
final flush at shutdown); the logger stays deterministic. The
service has no UIKit / AppKit / SwiftUI dependency and subscribes
to no process-lifecycle notification on its own — wire `start()`
and `stop()` from whatever lifecycle hooks the host already
manages.

```swift
let logger = AxiomLogger(wiring: wiring)
let service = AxiomLoggingService(logger: logger)
service.start()
```

The default `flushPolicy` is `.periodic(seconds: 30)`. Use
`.manual` to opt out of the periodic loop entirely and drive every
flush explicitly:

```swift
let manualService = AxiomLoggingService(
    logger: logger,
    flushPolicy: .manual,
    onDiagnostic: { diagnostic in
        // periodic + stop-time flush failures arrive here
        print("axiom service diagnostic: \(diagnostic)")
    }
)
manualService.start()  // no-op under `.manual`
_ = try await manualService.flush()  // explicit
await manualService.stop()  // also performs one final flush
```

`start()` is idempotent. `stop()` cancels the periodic loop,
awaits its exit, and performs exactly one final
`AxiomLogger.flush()` before returning. A throw from that final
flush — or from any periodic flush — surfaces through
`onDiagnostic` as `AxiomLoggingServiceDiagnostic.flushFailed(_:)`
instead of propagating. Explicit `service.flush()` calls re-throw
the underlying error verbatim.

## Response model

Axiom's ingest endpoint returns a **whole-request** status code
and a single `{"ingested": N, "failed": M, "failures": [...]}`-
shaped envelope. The adapter performs transport-level
success/failure classification only and treats the response body as
opaque payload bytes. Even on 2xx, the adapter does not compare
`ingested` / `failed` counts against the dispatched batch size. It
does **not** semantically parse or validate the response body for
per-item classification, so:

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

`swift-logger-axiom 0.2.0` deliberately ships no:

- autonomous scheduler on the durable delivery surface.
  `RemoteEngine.flush()` and `AxiomLogger.flush()` are
  caller-driven; host code wires them from whatever lifecycle
  hooks it cares about. `AxiomLoggingService` is the explicit
  opt-in periodic-flush coordinator and does not run unless the
  host calls `start()`.
- platform lifecycle observer. `AxiomLoggingService` runs a
  timer when opted into `.periodic(seconds:)` but subscribes to
  no process-lifecycle notification on its own.
- SDK / RUM integration. `swift-logger-axiom` is HTTP-only; Axiom
  does not ship a first-party iOS SDK.
- per-item parsing of Axiom's `failures` response array. The
  whole-batch 2xx -> success projection remains the transport
  contract.
- query / search API. This package writes events; reading is out
  of scope.
- direct mobile-safe token claims. The Axiom API token is
  extractable from any client binary that holds it; use
  `.intake(...)` for hardened production deployments.
- transport metadata on the `RemoteDeliveryEntry` payload. The
  `0.2.0` default encoder writes payload bytes only. Hosts that need
  routing hints should encode them as ordinary JSON fields in the
  event document or use an intake / proxy endpoint.
- in-logger retry of encoder, identifier, or enqueue failures.
  Diagnostics are surfaced; the entry is dropped.

## License

MIT. See [LICENSE](LICENSE).
