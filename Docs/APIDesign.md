# API design -- `swift-logger-axiom 0.1.0`

`swift-logger-axiom` is a durable-only Axiom HTTP ingest adapter
that bridges Axiom delivery onto `swift-logger-remote`'s
`RemoteEngine` + `DurableRemoteQueue` engine surface.

## Public surface

```text
public enum AxiomEndpoint: Sendable, Equatable {
    case axiom(url: URL, token: String)
    case intake(url: URL, authorizationHeader: String?)
}

public enum AxiomRemoteEngine {
    public struct Wiring: Sendable {
        public let queue: DurableRemoteQueue
        public let engine: RemoteEngine
    }

    public struct Configuration: Sendable {
        public let endpoint: AxiomEndpoint
        public let queueDirectory: URL
        public let exportDirectory: URL
        public let batchPolicy: RemoteBatchPolicy
        public let retryPolicy: RemoteRetryPolicy
        public let urlSession: URLSession
    }

    public static func make(_ configuration: Configuration) -> Wiring
}
```

The package exposes **nothing else** as `public`. The internal
`AxiomRemoteTransport`, `AxiomIngestTransport`,
`URLSessionAxiomIngestTransport`, `AxiomIngestTransportError`,
and `AxiomIngestRequestBody` types are package-internal and not
part of the API surface.

## Axiom endpoint trust model

`AxiomEndpoint` ships two cases that correspond to two distinct
deployment shapes. Pick the one that matches your trust model.

### `.axiom(url:token:)`

Direct delivery to Axiom's HTTP ingest endpoint. The adapter POSTs
to `url` **verbatim** -- it does not append, mutate, or guess the
URL path -- and sends `Authorization: Bearer <token>` on every
request. Pass the full dataset-scoped ingest URL (typically
`https://api.axiom.co/v1/datasets/<dataset>/ingest`, or the
equivalent on a regional Axiom Cloud deployment such as
`https://api.eu.axiom.co/v1/datasets/<dataset>/ingest`) so the
adapter never silently targets a different endpoint than the
operator authorized.

An Axiom API token compiled into a client app binary is
**extractable**. HTTPS protects the network hop, not secrets
embedded in the binary; anyone with the binary can recover the
token with standard reverse-engineering tooling. The Axiom dataset
behind that token inherits the trust level of the distribution
channel. Direct mode is appropriate for trial setups, internal-only
apps, prototypes, smoke tests, and any context where the operator
has consciously accepted that risk. For hardened production
deployments use `.intake(...)`.

### `.intake(url:authorizationHeader:)`

Delivery through a consumer-owned intake / proxy / gateway
endpoint. The adapter POSTs to `url` verbatim and sends the
consumer-supplied `Authorization` header value through unchanged
(Bearer, Basic, custom gateway tokens, or no auth when
`authorizationHeader` is `nil`). The intake service owns
authentication, dataset routing, rate limiting, schema evolution,
and duplicate-suppression policy; the real Axiom API token never
has to leave the server.

## Axiom request framing

`AxiomIngestRequestBody` (internal) builds the Axiom request body
from the ordered event payload bytes the engine hands the
transport for one batch round:

```
[<event_bytes_1>,<event_bytes_2>,...,<event_bytes_n>]
```

The layout matches Axiom's JSON ingest format: a top-level JSON
array whose elements are the host-provided event documents in
input order. The adapter does not wrap events in a per-event
metadata envelope; Axiom indexes each array element as a single
ingest event using the host-supplied JSON value verbatim.

`Content-Type` is `application/json`. `Authorization` is set when
the endpoint provides it (`Bearer <token>` for `.axiom`, the
caller's verbatim header for `.intake`); omitted when
`.intake(authorizationHeader: nil)`.

## `RemoteTransport.sendBatch(_:)` cardinality and ordering

`AxiomRemoteTransport.sendBatch(_:)` builds **exactly one** Axiom
HTTP request per non-empty call (the active batch becomes one
body). An empty `items` array returns `[]` without dispatching an
Axiom request. The returned result array has exactly `items.count`
entries; the result at index `i` corresponds to `items[i]`. The
engine fails closed with
`RemoteEngineError.transportBatchInvalid(expected:actual:)` if
that count contract breaks.

### 2xx success

Axiom's ingest endpoint returns a whole-request 2xx status when
the request is accepted, with a response body of the shape
`{"ingested": N, "failed": M, "failures": [...]}` carrying
per-item success / failure counts and an optional `failures`
array describing rejected items. `0.1.0` performs transport-level
success/failure classification only and does **not** semantically
parse or validate the response body for per-item classification,
so a 2xx ingest reply resolves every input item to `.success`
carrying the opaque response bytes Axiom returned.

### Whole-request failure

Anything that prevents a 2xx Axiom response (non-2xx status,
network error, transport-level response-shape failures,
request-build error) throws from `sendBatch(_:)`. The engine
treats the throw as a transport-level failure for every active
item in the batch round and runs each item through `classify(_:)`
with the same `.failure(error)` value.

## Classification policy

`AxiomRemoteTransport.classify(_:)` is sink-owned. The engine
never inspects HTTP status or transport error types. The mapping
table:

| Input | Mapping |
| ----- | ------- |
| `.success(_)` | `.success` |
| HTTP 408 / 429 / 5xx | `.retryable(.transportRejected)` |
| HTTP 401 / 403 | `.terminal(.transportRejected)` |
| Other HTTP 4xx (400 / 404 / 405 / 409 / 422 / ...) | `.terminal(.transportRejected)` |
| `AxiomIngestTransportError.invalidResponse` | `.retryable(.transportRejected)` |
| Unexpected HTTP status classes from the Axiom endpoint | `.retryable(.transportRejected)` for forward compatibility (fail-safe default) |
| Any other error (URLError, DNS, TLS, cancellation, request-build, ...) | `.retryable(.transportRejected)` |

Classification is deterministic for the same adapter
implementation and transport result within a flush pass. It does
not mutate queue acknowledgement state or export-file lifecycle
state directly or indirectly.

The 408 / 429 / 5xx -> retryable mapping reflects Axiom's
documented ingest error model:

- HTTP 429 ("Too Many Requests") is the backpressure signal when
  the dataset's ingest budget is exhausted; the engine's retry
  budget is the right place to drain it.
- HTTP 5xx (500 / 502 / 503 / 504) signals Axiom-side transient
  failure that may clear on retry.
- HTTP 408 is a transport-level request-timeout signal.

401 / 403 / 400 -> terminal reflects:

- HTTP 401 ("Unauthorized") and HTTP 403 ("Forbidden") -- the
  token is missing, invalid, or lacks the dataset permission;
  retrying with the same credential will not help.
- HTTP 400 ("Bad Request") covers malformed JSON, schema
  violations, or unknown dataset addressing -- retrying with the
  same request shape will not help.
- HTTP 404 ("Not Found") indicates the dataset does not exist or
  the URL is wrong; retrying without operator intervention will
  not help.

## Remote-engine lifecycle ownership

`swift-logger-axiom` owns:

- Axiom JSON array request framing from the ordered host-encoded
  event payload bytes provided by the engine.
- Axiom response classification by HTTP status code.

`swift-logger-remote` owns:

- The durable queue (`DurableRemoteQueue`).
- Batch-round retry budget and the batch-round dispatcher.
- Retained export artifact reuse on retryable continuations across
  flush passes.
- Acknowledgement-to-removal lifecycle (no destructive removal
  until the engine acknowledges a fully-resolved non-empty flush
  pass).

The adapter never re-implements those concerns. The engine is
caller-driven: it owns no timer, no platform lifecycle observer,
no autonomous scheduler. Hosts wire `flush()` calls from their
own lifecycle hooks or scheduling infrastructure.

## Why retry / ACK / persistence stay in `swift-logger-remote`

Putting retry, persistence, and acknowledgement into every
adapter would duplicate the state the engine already owns and
would risk sink-specific lifecycle drift, diverging the contract
across sinks (one adapter would acknowledge under different
conditions than another). Keeping those concerns in
`swift-logger-remote` means this adapter only owns the wire-
format and classification rules specific to the Axiom HTTP
ingest endpoint; the engine's lifecycle contract stays the same
regardless of the HTTP wire format.
