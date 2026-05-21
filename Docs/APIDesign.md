# API design -- `swift-logger-axiom 0.2.0`

`swift-logger-axiom` is an Axiom HTTP ingest adapter that bridges
Axiom delivery onto `swift-logger-remote`'s `RemoteEngine` +
`DurableRemoteQueue` engine surface, plus a batteries-included
`Loggers.Logger` adapter (`AxiomLogger`) that admits log entries
non-blockingly and routes them through that engine.

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

public struct AxiomLogger: Loggers.Logger {
    public enum MinimumLevel: String, CaseIterable, Sendable {
        case trace, debug, info, notice, warning, error, critical
    }

    public init(
        wiring: AxiomRemoteEngine.Wiring,
        encoder: any AxiomLogEventEncoder = AxiomDefaultLogEventEncoder(),
        identifierProvider: any AxiomIdentifierProvider = AxiomMonotonicIdentifierProvider(),
        bufferPolicy: AxiomLoggerBufferPolicy = .dropNewest(capacity: 1_000),
        minimumLevel: MinimumLevel = .trace,
        onDiagnostic: (@Sendable (AxiomLoggerDiagnostic) -> Void)? = nil
    )

    public func log(
        _ level: LoggerLevel,
        _ domain: LoggerDomain,
        _ message: @autoclosure @escaping @Sendable () -> LogMessage,
        attributes: @autoclosure @escaping @Sendable () -> [LogAttribute]
    )

    public func flush() async throws -> RemoteFlushSummary
}

public struct AxiomLogEvent: Sendable, Equatable {
    public let timestamp: Date
    public let level: LoggerLevel
    public let domain: LoggerDomain
    public let message: LogMessage
    public let attributes: [LogAttribute]
}

public protocol AxiomLogEventEncoder: Sendable {
    func encode(_ event: AxiomLogEvent) throws -> Data
}

public struct AxiomDefaultLogEventEncoder: AxiomLogEventEncoder { ... }

public protocol AxiomIdentifierProvider: Sendable {
    func nextIdentifier() throws -> UInt64
}

public struct AxiomMonotonicIdentifierProvider: AxiomIdentifierProvider { ... }

public enum AxiomMonotonicIdentifierError: Error, Sendable, Equatable {
    case exhausted
}

public enum AxiomLoggerBufferPolicy: Sendable, Equatable {
    case dropNewest(capacity: Int)
    case dropOldest(capacity: Int)
}

public enum AxiomLoggerDiagnostic: Sendable, Equatable {
    case bufferFull(dropped: Int)
    case encodingFailed(String)
    case identifierFailed(String)
    case enqueueFailed(String)
    case admissionSequenceExhausted
}

public enum AxiomFlushPolicy: Sendable, Equatable {
    case manual
    case periodic(seconds: TimeInterval)
}

public enum AxiomLoggingServiceDiagnostic: Sendable, Equatable {
    case flushFailed(String)
    case invalidFlushInterval(seconds: TimeInterval)
}

public final class AxiomLoggingService: Sendable {
    public init(
        logger: AxiomLogger,
        flushPolicy: AxiomFlushPolicy = .periodic(seconds: 30),
        onDiagnostic: (@Sendable (AxiomLoggingServiceDiagnostic) -> Void)? = nil
    )

    public func start()
    public func stop() async

    @discardableResult
    public func flush() async throws -> RemoteFlushSummary
}
```

The package exposes **nothing else** as `public`. The internal
`AxiomRemoteTransport`, `AxiomIngestTransport`,
`URLSessionAxiomIngestTransport`, `AxiomIngestTransportError`,
`AxiomIngestRequestBody`, and `AxiomLoggerStorage` types are
package-internal and not part of the API surface.

## AxiomLogger admission and worker

`AxiomLogger` is a lightweight sendable logger handle backed by
shared reference storage. The storage owns the bounded admission
buffer, the admission sequence counter, the flush barriers, the
diagnostic callback, and a single internal serial worker. Producers
admit entries through the synchronous
``AxiomLogger/log(_:_:_:attributes:)`` method; the internal worker
materializes each accepted entry, allocates its identifier, encodes
it, and hands the resulting payload bytes to
``DurableRemoteQueue/enqueue(_:)`` in admission order. The worker is
implementation-private and not actor-isolated API surface.

### Drop guards

Two drop guards run at the call site, **before** any closure is
evaluated:

- Entries tagged `LoggerLevel.disabled` are rejected
  unconditionally.
- Entries whose level is below `minimumLevel` are rejected.

`minimumLevel` is typed as ``AxiomLogger/MinimumLevel`` (a
`CaseIterable`, `Sendable` enum with exactly seven cases — the seven
`Loggers.LoggerLevel` severities). The cross-adapter contract
documented in the ecosystem roadmap forbids `LoggerLevel.disabled`
as a threshold; the nested enum enforces that statically at the
API surface so a caller cannot mistakenly drop every entry.

A third drop guard applies under
``AxiomLoggerBufferPolicy/dropNewest(capacity:)`` when the buffer
is full: the new entry is rejected without evaluating its
autoclosures. Under
``AxiomLoggerBufferPolicy/dropOldest(capacity:)`` the oldest
pending entry is evicted (also without evaluating it) and the new
entry is admitted for later worker evaluation.

### Worker pipeline

For every accepted pending entry the worker:

1. Calls the `message` autoclosure exactly once and the
   `attributes` autoclosure exactly once.
2. Builds an ``AxiomLogEvent`` carrying the admission-time
   timestamp.
3. Calls the configured ``AxiomLogEventEncoder``. A throw
   surfaces ``AxiomLoggerDiagnostic/encodingFailed(_:)`` and the
   entry is dropped.
4. Calls the configured ``AxiomIdentifierProvider``. A throw
   surfaces ``AxiomLoggerDiagnostic/identifierFailed(_:)`` and the
   entry is dropped.
5. Calls ``DurableRemoteQueue/enqueue(_:)``. A throw surfaces
   ``AxiomLoggerDiagnostic/enqueueFailed(_:)``; the logger does
   not locally retry the entry. The engine's own durable-delivery
   lifecycle is unaffected by this diagnostic.

### Flush barrier

An accepted pending entry is a log entry successfully admitted into
``AxiomLogger``'s internal buffer. ``AxiomLogger/flush()`` waits
until every entry already admitted at the moment of the call has
reached one of the terminal states above (enqueued or diagnostic
failure), then runs ``RemoteEngine/flush()`` and forwards its
``RemoteFlushSummary``. Entries dropped at admission are not part of
the barrier because they were never accepted; entries admitted
**after** `flush()` was invoked are also not part of the barrier
(they form the next flush's drain target).

### Identifier and ordering contract

Per-caller serial ordering is preserved: a caller that emits
entries A, B, C in order sees them reach the queue in the same
order. No global ordering guarantee is made across concurrent
callers. Identifiers are monotonic in worker dequeue order, not in
wall-clock call order; under contention an entry admitted slightly
later on one caller may receive an earlier identifier than one
admitted slightly earlier on a different caller.

The default ``AxiomMonotonicIdentifierProvider`` allocates
process-local IDs that reset on every fresh process. Consumers
that need persistent deduplication identity across launches must
supply their own ``AxiomIdentifierProvider`` implementation.

### Diagnostics

The optional `onDiagnostic` callback receives ``AxiomLoggerDiagnostic``
values. The invocation context is split by diagnostic kind:

- ``AxiomLoggerDiagnostic/bufferFull(dropped:)`` and
  ``AxiomLoggerDiagnostic/admissionSequenceExhausted`` fire
  **synchronously on the caller's** ``AxiomLogger/log(_:_:_:attributes:)``
  **path**. The buffer-policy decision (or the
  `acceptedSequence == UInt64.max` exhaustion guard) is made under
  the admission lock; the diagnostic is dispatched on the same
  thread that called `log(...)` once the lock has been released.
- ``AxiomLoggerDiagnostic/encodingFailed(_:)``,
  ``AxiomLoggerDiagnostic/identifierFailed(_:)``, and
  ``AxiomLoggerDiagnostic/enqueueFailed(_:)`` fire on the **internal
  worker context** when the corresponding step throws while the
  worker is materializing an accepted entry.

The callback must satisfy the `@Sendable` contract in both cases.
String payloads use `String(describing: error)`, not
`localizedDescription`, so the diagnostic carries a stable spelling
regardless of the upstream error's `LocalizedError` conformance.

## `AxiomLoggingService`

``AxiomLoggingService`` is an optional convenience over explicit
``AxiomLogger/flush()``. It owns scheduling; the logger stays
deterministic. The service declares no UIKit / AppKit / SwiftUI /
WatchKit dependency and subscribes to no process-lifecycle
notification on its own — integration with platform lifecycle hooks
(background notifications, shutdown signals) remains the caller's
responsibility.

### Flush policy

``AxiomFlushPolicy/manual`` runs no internal periodic loop. The
service only drives flushes the host requests explicitly through
``AxiomLoggingService/flush()`` plus the single final flush
performed inside ``AxiomLoggingService/stop()``.

``AxiomFlushPolicy/periodic(seconds:)`` launches one internal task
on ``AxiomLoggingService/start()``. Each iteration sleeps for the
configured interval and then awaits one ``AxiomLogger/flush()`` to
completion before sleeping again. Two periodic flushes on the same
service instance never overlap. A non-positive, non-finite, or
sub-nanosecond positive interval (any value that truncates to
zero nanoseconds) is rejected at ``AxiomLoggingService/start()``
time: the service starts no periodic loop, surfaces
``AxiomLoggingServiceDiagnostic/invalidFlushInterval(seconds:)``
through the `onDiagnostic` callback, and behaves as
``AxiomFlushPolicy/manual`` thereafter.

### Lifecycle

``AxiomLoggingService/start()`` is idempotent. Repeated calls do
not launch additional periodic loops, and a call after
``AxiomLoggingService/stop()`` is a no-op.

``AxiomLoggingService/stop()`` cancels the periodic loop, awaits
its exit, and performs exactly one final ``AxiomLogger/flush()``
before returning. A throw from that final flush surfaces through
the `onDiagnostic` callback as
``AxiomLoggingServiceDiagnostic/flushFailed(_:)`` instead of
re-throwing from ``AxiomLoggingService/stop()``. Subsequent
``AxiomLoggingService/stop()`` calls return immediately and do not
re-run the final flush.

``AxiomLoggingService/flush()`` forwards directly to
``AxiomLogger/flush()`` and returns the resulting
`RemoteFlushSummary`. A throw is re-thrown to the caller verbatim;
the diagnostic callback is not invoked for explicit-flush failures.

### Service diagnostics

The optional `onDiagnostic` callback receives
``AxiomLoggingServiceDiagnostic`` values for two failure modes:

- ``AxiomLoggingServiceDiagnostic/flushFailed(_:)`` fires when the
  periodic loop or the final flush inside
  ``AxiomLoggingService/stop()`` throws. The callback runs on the
  internal task context. The string payload uses
  `String(describing: error)`, identical to the
  ``AxiomLoggerDiagnostic`` convention.
- ``AxiomLoggingServiceDiagnostic/invalidFlushInterval(seconds:)``
  fires synchronously on the caller's ``AxiomLoggingService/start()``
  thread when ``AxiomFlushPolicy/periodic(seconds:)`` carries a
  non-positive, non-finite, or sub-nanosecond positive interval
  (any value that truncates to zero nanoseconds).

The callback must satisfy the `@Sendable` contract in both cases.

## Default JSON event schema

``AxiomDefaultLogEventEncoder`` emits one JSON object per event:

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

Field contract:

- `_time` -- RFC 3339 wall-clock string with fractional-second
  precision (`yyyy-MM-ddTHH:mm:ss.SSSZ`), always in UTC.
- `level` -- ``LoggerLevel/rawValue`` of the accepted entry.
- `domain` -- ``LoggerDomain/rawValue`` of the accepted entry.
- `message` -- ``LogMessage/redactedDescription`` (private
  segments render as `<private>`, sensitive segments as
  `<redacted>`).
- `attributes` -- JSON object built from the entry's attributes.
  Duplicate keys resolve last-wins. Private attribute values
  render as the string `<private>`; sensitive values render as
  `<redacted>`. ``LogValue`` cases map onto JSON primitives;
  ``Date`` values use the same RFC 3339 spelling as `_time`;
  non-finite `Double` values render through the stable fallback
  path as `String(describing: value)`.

The default encoder never throws for any
``AxiomLogEvent`` constructable from a ``Loggers/Logger`` call;
unsupported attribute values flow through the stable fallback
path rather than failing the entry.

## Transport framing

The payload bytes ``AxiomLogger`` enqueues into
``DurableRemoteQueue/enqueue(_:)`` are admitted as
``RemoteDeliveryEntry/payload`` and framed by the internal
``AxiomIngestRequestBody`` helper into the Axiom ingest JSON
array `[<event_1>,<event_2>,...]` with no further interpretation,
metadata wrapping, or transformation.

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
array describing rejected items. The adapter performs
transport-level success/failure classification only and treats the
response body as opaque payload bytes. It does **not** semantically
parse or validate the response body for per-item classification, so a
2xx ingest reply resolves every input item to `.success` carrying the
opaque response bytes Axiom returned.

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

The adapter never re-implements those concerns. The engine and
``AxiomLogger`` are caller-driven: neither owns a timer, a
platform lifecycle observer, or an autonomous scheduler. Hosts
wire `flush()` from their own lifecycle hooks, scheduling
infrastructure, or the optional ``AxiomLoggingService``
periodic-flush coordinator (`AXM-35..45`); the service runs a
timer only when the host opts into
``AxiomFlushPolicy/periodic(seconds:)`` and calls
``AxiomLoggingService/start()``.

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
