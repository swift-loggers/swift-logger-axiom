# Requirements -- `swift-logger-axiom 0.2.0`

This document locks the requirement IDs (`AXM-*`) that
`swift-logger-axiom 0.2.0` ships and tests against. Each ID is
mapped to its enforcing test in
[`Tests/LoggerAxiomTests/CoverageMap.md`](../Tests/LoggerAxiomTests/CoverageMap.md).

`AXM-1` through `AXM-15` shipped in `0.1.0` and describe the
durable Axiom HTTP ingest path (`AxiomRemoteEngine` factory, the
`RemoteTransport.sendBatch(_:)` contract, classification, the
endpoint trust model, and the engine-lifecycle ownership rules).
`AXM-16` through `AXM-34` ship in `0.2.0` and describe the new
`AxiomLogger` admission, worker, default encoder, transport framing,
threshold-enum, and admission-sequence-exhaustion contracts.
`AXM-35` through `AXM-45` ship in `0.2.0` and describe the new
`AxiomLoggingService` flush coordinator (lifecycle idempotency,
policy semantics, non-overlapping periodic cadence, explicit flush
forwarding, stop-time final flush, diagnostic surface, platform
independence, invalid-interval rejection, and periodic-loop
cancellation on deallocation).

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
this adapter. The adapter performs transport-level success/failure
classification only and treats the response body as opaque payload
bytes. It does not semantically parse or validate the response body,
so a 2xx Axiom reply resolves every input item to `.success`
carrying the opaque response bytes Axiom returned.

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

`RemoteEngine.flush()` and ``AxiomLogger/flush()`` are
caller-driven; neither installs an autonomous scheduler,
platform lifecycle observer, or timer. Hosts wire `flush()`
from their own lifecycle hooks or scheduling infrastructure
(background notifications, shutdown signals, periodic tasks).
Periodic scheduling is available as an explicit opt-in through
``AxiomLoggingService`` (`AXM-35..45`); the service runs a
timer only after the host calls ``AxiomLoggingService/start()``
and subscribes to no process-lifecycle notification on its
own.

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

## `AxiomLogger` admission and worker

### `AXM-16` `AxiomLogger(wiring:)` default-configurable

`AxiomLogger(wiring:)` is constructable with the default
``AxiomDefaultLogEventEncoder`` and the default
``AxiomMonotonicIdentifierProvider``. An admitted entry flows
through the worker, is eventually enqueued through
``DurableRemoteQueue/enqueue(_:)``, and ``AxiomLogger/flush()``
invokes the engine flush pass and returns the resulting
``RemoteFlushSummary``.

### `AXM-17` `LoggerLevel.disabled` drop never evaluates closures

An entry tagged ``LoggerLevel/disabled`` is rejected at the call
site without evaluating its `message` or `attributes` autoclosures.
No internal buffer admission and no diagnostic callback fires for
the rejection.

### `AXM-18` Below-minimum drop never evaluates closures

An entry whose level is below the configured `minimumLevel` is
rejected at the call site without evaluating its `message` or
`attributes` autoclosures. No internal buffer admission and no
diagnostic callback fires for the rejection.

`minimumLevel` is typed as ``AxiomLogger/MinimumLevel`` (the
nested enum locked by `AXM-33`); `LoggerLevel.disabled` is not
expressible as a threshold through the public API.

### `AXM-19` Accepted entry evaluates closures exactly once

For every accepted pending entry the internal worker evaluates the
`message` autoclosure exactly once and the `attributes` autoclosure
exactly once across the entry's lifetime. ``AxiomLogger`` itself
performs no retries and never re-evaluates accepted closures.

### `AXM-20` `.dropNewest` drops the new entry without evaluation

When the bounded buffer is full and the policy is
``AxiomLoggerBufferPolicy/dropNewest(capacity:)``, the new entry is
rejected without evaluating its `message` or `attributes`
autoclosures. The buffer is unchanged. The diagnostic callback
fires ``AxiomLoggerDiagnostic/bufferFull(dropped:)`` with `dropped:
1` per rejected admission.

### `AXM-21` `.dropOldest` evicts the oldest pending entry

When the bounded buffer is full and the policy is
``AxiomLoggerBufferPolicy/dropOldest(capacity:)``, the oldest
pending entry is evicted (without evaluating its `message` or
`attributes` autoclosures) and the new entry is admitted for later
worker evaluation. The diagnostic callback fires
``AxiomLoggerDiagnostic/bufferFull(dropped:)`` with `dropped: 1`
per evicted entry.

### `AXM-22` Encoder failure surfaces `encodingFailed`

When the configured ``AxiomLogEventEncoder`` throws while encoding
an accepted entry, the worker drops the entry and surfaces
``AxiomLoggerDiagnostic/encodingFailed(_:)`` with
`String(describing: error)`. The failing entry is not enqueued.

### `AXM-23` Identifier failure surfaces `identifierFailed`

When the configured ``AxiomIdentifierProvider`` throws while
allocating an identifier for an accepted entry, the worker drops
the entry and surfaces
``AxiomLoggerDiagnostic/identifierFailed(_:)`` with
`String(describing: error)`. The failing entry is not enqueued.

### `AXM-24` Enqueue failure surfaces `enqueueFailed`

When ``DurableRemoteQueue/enqueue(_:)`` throws for an accepted
entry after encoding and identifier allocation succeeded, the
worker surfaces ``AxiomLoggerDiagnostic/enqueueFailed(_:)`` with
`String(describing: error)`. The logger does not locally retry the
entry; the engine's own durable-delivery lifecycle is unaffected by
this diagnostic.

### `AXM-25` Flush drains accepted pending before engine flush

An accepted pending entry is a log entry successfully admitted into
``AxiomLogger``'s internal buffer. ``AxiomLogger/flush()`` returns
to the caller only after every entry already admitted at the moment
of the call has either been enqueued onto the durable queue or
surfaced a diagnostic failure (encoding, identifier allocation, or
enqueue). After the drain barrier resolves, `flush()` invokes the
engine flush closure and forwards its ``RemoteFlushSummary``.
Entries admitted **after** `flush()` was invoked are not part of the
barrier.

### `AXM-26` Per-caller serial ordering preserved

For a single caller that emits entries A, B, C in that order, the
internal worker hands them to the enqueue closure in the same
order. No global ordering guarantee is made across concurrent
callers; identifiers are monotonic in worker dequeue order, not in
wall-clock call order.

### `AXM-27` Concurrent admissions have unique identifiers

The default ``AxiomMonotonicIdentifierProvider`` returns a distinct
`UInt64` for every accepted entry across concurrent admissions
within a single process lifetime until `UInt64` exhaustion. Combined
with the worker's serial allocation, every enqueued
``RemoteDeliveryEntry`` carries a unique identifier.

## Default encoder

### `AXM-28` Documented JSON field names

``AxiomDefaultLogEventEncoder`` emits one JSON object per event
with the field names `_time`, `level`, `domain`, `message`, and
`attributes`. `_time` is an RFC 3339 wall-clock string with
fractional-second precision (`yyyy-MM-ddTHH:mm:ss.SSSZ`), always in
UTC. Non-finite `Double` attribute values flow through the stable
string fallback (`String(describing: value)`).

### `AXM-29` Default encoder redacts message segment privacy

Private message segments render as the literal string `<private>`
and sensitive message segments render as `<redacted>`. Public
segments render verbatim. The rendering is performed through
``LogMessage/redactedDescription`` so the contract matches the
core `Loggers` library's privacy degradation rule.

### `AXM-30` Default encoder redacts attribute value privacy

Private attribute values render as the literal string `<private>`
and sensitive attribute values render as `<redacted>`. Public
attribute values render through their JSON-native primitive
spelling. The privacy annotation is consulted per attribute,
independent of the message's privacy annotation.

### `AXM-31` Duplicate attribute keys resolve last-wins

When an entry carries multiple ``LogAttribute`` values that share
the same key, the encoded `attributes` JSON object contains the
value from the **last** occurrence in the call-site order.

### `AXM-32` Encoded payload framed verbatim by the transport

The payload bytes produced by ``AxiomDefaultLogEventEncoder`` are
admitted into `DurableRemoteQueue.enqueue(_:)` as
`RemoteDeliveryEntry.payload` and framed by the internal
``AxiomIngestRequestBody`` helper into a JSON array
`[<event_1>,<event_2>,...]` with no further interpretation,
metadata wrapping, or transformation.

### `AXM-33` Threshold uses nested `MinimumLevel` enum

The public `minimumLevel` parameter of
``AxiomLogger/init(wiring:encoder:identifierProvider:bufferPolicy:minimumLevel:onDiagnostic:)``
is typed as ``AxiomLogger/MinimumLevel`` — a `CaseIterable`,
`Sendable` enum with exactly seven cases (`.trace`, `.debug`,
`.info`, `.notice`, `.warning`, `.error`, `.critical`). The
ecosystem-wide cross-adapter rule forbids
`LoggerLevel.disabled` as a threshold value; this enum enforces
that statically at the API surface.

### `AXM-34` Admission sequence exhaustion

The internal admission-sequence allocator never wraps past
`UInt64.max`. When the allocator has issued `UInt64.max`
sequences and an additional admission is offered:

- the new entry is rejected and the `acceptedSequence` counter
  stays at `UInt64.max` (no wrap to `0`),
- the entry's `message` and `attributes` autoclosures are not
  evaluated,
- no pending entry is evicted regardless of the configured
  ``AxiomLoggerBufferPolicy``,
- the worker is not woken,
- the diagnostic callback receives
  ``AxiomLoggerDiagnostic/admissionSequenceExhausted``.

Every subsequent admission on the same logger instance fires
the diagnostic again. The condition is a hard stop on that
instance and does not propagate to other loggers or to the
engine's durable-delivery lifecycle.

## `AxiomLoggingService`

### `AXM-35` Start idempotency

``AxiomLoggingService/start()`` is idempotent. Repeated calls do
not launch additional internal periodic loops. A call after
``AxiomLoggingService/stop()`` is a no-op.

### `AXM-36` Manual policy has no periodic loop

Under ``AxiomFlushPolicy/manual``, ``AxiomLoggingService/start()``
starts no periodic task. The only flushes the service drives are
explicit ``AxiomLoggingService/flush()`` calls and the single
final flush performed inside ``AxiomLoggingService/stop()``.

### `AXM-37` Periodic policy drives flushes

Under ``AxiomFlushPolicy/periodic(seconds:)`` with a finite,
positive interval, ``AxiomLoggingService/start()`` launches one
internal task that sleeps for the configured interval and then
drives one ``AxiomLogger/flush()`` per tick.

### `AXM-38` Periodic flushes are serial

The periodic loop awaits each ``AxiomLogger/flush()`` to
completion before starting the next sleep. Two periodic flushes
on the same service instance never overlap. The service runs at
most one periodic task per instance.

### `AXM-39` Explicit flush forwards

``AxiomLoggingService/flush()`` forwards directly to
``AxiomLogger/flush()`` and returns the resulting
`RemoteFlushSummary`. A throw from the underlying flush is
re-thrown to the caller verbatim; the diagnostic callback is not
invoked for explicit-flush failures.

### `AXM-40` Stop cancels and performs final flush

``AxiomLoggingService/stop()`` cancels the periodic loop, awaits
its exit, and performs exactly one final ``AxiomLogger/flush()``
before returning. After any ``AxiomLoggingService/stop()`` call
returns, no further periodic flush fires and the final flush has
completed. Concurrent or subsequent ``AxiomLoggingService/stop()``
calls join the in-flight stop and return only after that stop
work completes; the final flush runs exactly once per service
instance.

### `AXM-41` Periodic failure surfaces diagnostic

A throw from a periodic ``AxiomLogger/flush()`` surfaces
``AxiomLoggingServiceDiagnostic/flushFailed(_:)`` via the
`onDiagnostic` callback with `String(describing: error)`. The
periodic loop continues running and the next sleep starts as
usual.

### `AXM-42` Stop-time final flush failure surfaces diagnostic

A throw from the final ``AxiomLogger/flush()`` inside
``AxiomLoggingService/stop()`` surfaces
``AxiomLoggingServiceDiagnostic/flushFailed(_:)`` via the
`onDiagnostic` callback instead of re-throwing from
``AxiomLoggingService/stop()``.

### `AXM-43` Platform independence

``AxiomLoggingService`` and its supporting types
(``AxiomFlushPolicy``, ``AxiomLoggingServiceDiagnostic``) declare
no UIKit / AppKit / SwiftUI / WatchKit imports. The service does
not subscribe to any process-lifecycle notification on its own;
integration with platform lifecycle callbacks is the caller's
responsibility.

### `AXM-44` Invalid periodic interval rejected without hot loop

``AxiomLoggingService/start()`` called with
``AxiomFlushPolicy/periodic(seconds:)`` where `seconds` is
non-positive, non-finite, or so small that it truncates to zero
nanoseconds does not launch a periodic loop. The service marks
itself as started, surfaces
``AxiomLoggingServiceDiagnostic/invalidFlushInterval(seconds:)``
through the `onDiagnostic` callback with the offending value, and
behaves as ``AxiomFlushPolicy/manual`` thereafter. The final flush
inside ``AxiomLoggingService/stop()`` still runs as for any other
policy.

### `AXM-45` Periodic loop cancelled on deallocation

Deallocating an ``AxiomLoggingService`` cancels its periodic
loop. Cancellation interrupts the loop's next `Task.sleep` and
prevents any further iteration; any flush already in flight
when deallocation runs completes on its own and is not aborted.
``AxiomLoggingService/stop()`` remains the only path that
initiates a final ``AxiomLogger/flush()``; deallocation alone
does not initiate a flush.

## Non-goals

`swift-logger-axiom 0.2.0` deliberately ships no:

- autonomous scheduler on the durable delivery surface:
  ``AxiomLogger/flush()`` is caller-driven, and the optional
  ``AxiomLoggingService`` periodic loop runs only when the host
  calls ``AxiomLoggingService/start()`` under
  ``AxiomFlushPolicy/periodic(seconds:)``.
- platform lifecycle observer. ``AxiomLoggingService`` does not
  subscribe to any process-lifecycle notification on its own.
- SDK / RUM integration (HTTP-only -- Axiom does not ship a
  first-party iOS SDK).
- per-item parsing of Axiom's `failures` response array; whole-
  batch 2xx -> success projection remains the transport contract.
- query / search API.
- direct mobile-safe token claims.
- transport metadata on the `RemoteDeliveryEntry`; the
  [`AXM-32`](#axm-32-encoded-payload-framed-verbatim-by-the-transport)
  payload / framing contract keeps encoded payload bytes verbatim, and
  the default `0.2.0` encoder writes payload bytes only. Hosts that need
  routing hints should encode them as ordinary JSON fields in the event
  document or use an intake / proxy endpoint.
- in-logger retry of encoder, identifier, or enqueue failures.
  Diagnostics are surfaced; the entry is dropped.
