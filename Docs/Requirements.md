# Requirements -- `swift-logger-axiom 0.1.0`

This document locks the requirement IDs (`AXM-*`) that
`swift-logger-axiom 0.1.0` ships and tests against. Each ID is
mapped to its enforcing test in
[`Tests/LoggerAxiomTests/CoverageMap.md`](../Tests/LoggerAxiomTests/CoverageMap.md).

## Payload contract

### `AXM-1` Lazy host-side encoding boundary

`DurableRemoteQueue.enqueue(_:)` admits a `RemoteDeliveryEntry`
whose `payload` is **opaque pre-encoded bytes**. For this Axiom
wiring those bytes are one **event document** -- a complete JSON
value that Axiom indexes as a single ingest event (typically a
JSON object). Neither the engine nor the internal Axiom transport
encodes upstream host log records on the caller's behalf.

### `AXM-2` JSON array request body framing

The Axiom request body is a single JSON array whose elements are
the host-encoded event documents in input order:

```
[<event_1>,<event_2>,...,<event_n>]
```

The adapter does **not** wrap events in a per-event metadata
envelope; the host-provided JSON value appears in the array
verbatim. An empty `events` array produces an empty body so the
caller can skip dispatching an HTTP request.

## `RemoteTransport.sendBatch(_:)` contract

### `AXM-3` One Axiom request per non-empty `sendBatch(_:)` call

The transport builds exactly one Axiom HTTP request per non-empty
`sendBatch(_:)` call. The active batch is the request body; no
per-event request is issued. An empty `items` array returns `[]`
without dispatching an Axiom request.

### `AXM-4` One result per input item

The returned result array has exactly `items.count` entries.

### `AXM-5` Input-order preservation

The result at index `i` corresponds to `items[i]`. Likewise the
events in the request body appear in input order so a downstream
indexer can correlate by position.

### `AXM-6` 2xx success projection

Axiom's ingest endpoint returns a whole-request status for the
current batch round; per-item failures appear in the response
body's `failures` array but are intentionally **not** parsed by
`0.1.0`. The adapter performs transport-level success/failure
classification only and does not semantically parse or validate
the response body, so a 2xx Axiom reply resolves every input item
to `.success` carrying the opaque response bytes Axiom returned.

### `AXM-7` Whole-batch failure projection

Anything that prevents a 2xx Axiom response (non-2xx status,
network error, transport-level response-shape failure (for example,
non-HTTP responses), request-build error) throws from
`sendBatch(_:)`. The engine routes the throw through `classify(_:)`
for every active item in the batch round.

## Classification policy

### `AXM-8` Retryable mapping

HTTP 408 / 429 / 5xx, `AxiomIngestTransportError.invalidResponse`,
and arbitrary errors (URLError, DNS, TLS, cancellation, ...)
classify as `.retryable(.transportRejected)`. Unexpected HTTP
status classes also classify as retryable for forward compatibility
(fail-safe default).

### `AXM-9` Terminal mapping

HTTP 401 / 403 and other HTTP 4xx (400 / 404 / 405 / 409 / 422 /
...) classify as `.terminal(.transportRejected)`.

### `AXM-10` Deterministic classification

`classify(_:)` is deterministic for the same adapter
implementation and transport result within a flush pass. It does
not mutate queue acknowledgement state or export-file lifecycle
state directly or indirectly. Repeated classification invocations
for the same result within a flush pass MUST return the same
decision.

## Endpoint trust model

### `AXM-11` Direct Axiom token threat model

`.axiom(url:token:)` POSTs to `url` verbatim with
`Authorization: Bearer <token>`. The Axiom API token is
extractable from any client binary that holds it; production iOS /
macOS apps should route through `.intake(...)` instead.

### `AXM-12` Intake authorization passthrough

`.intake(url:authorizationHeader:)` sends the consumer-supplied
`Authorization` header value through unchanged when non-`nil`,
and omits the header entirely when `nil`. The intake URL is sent
verbatim.

## Engine lifecycle ownership

### `AXM-13` Caller-driven flush lifecycle

The package installs no autonomous scheduler, no platform
lifecycle observer, and no timer. `RemoteEngine.flush()` is
caller-driven; hosts wire `flush()` from their own lifecycle
hooks or scheduling infrastructure (background notifications,
shutdown signals, periodic tasks).

### `AXM-14` Retained outstanding batch reuse

A `.retryable` outcome anywhere in a flush pass keeps the queue's
outstanding batch retained. The next `flush()` reuses the retained
drained bytes through the engine's outstanding-reuse path for the
retained outstanding batch across flush passes; no fresh queue
drain runs while an outstanding batch is retained.

### `AXM-15` Acknowledgement-to-removal lifecycle

`RemoteEngine.flush()` acknowledges (removes the delivered queue
payload bytes) only when every recovered entry across the pass
resolves as `.success` or `.terminal`. A pass-wide `.terminal`-
only resolution still acknowledges (the classifier declared the
entries permanently failed; removing those bytes is forward
progress, not data loss).

## Non-goals

`swift-logger-axiom 0.1.0` deliberately ships no:

- best-effort in-memory `AxiomLogger` (durable-only M4.1 scope).
- autonomous scheduler or timer.
- platform lifecycle observer.
- SDK / RUM integration (HTTP-only -- Axiom does not ship a
  first-party iOS SDK).
- per-item parsing of Axiom's `failures` response array; whole-
  batch 2xx -> success projection is the `0.1.0` contract.
- query / search API.
- direct mobile-safe token claims.
