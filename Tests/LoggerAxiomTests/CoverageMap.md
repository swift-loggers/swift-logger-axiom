# Coverage map -- `swift-logger-axiom 0.2.0`

Each requirement ID locked in
[`Docs/Requirements.md`](../../Docs/Requirements.md) maps to the
test (or tests) that enforce it.

`AXM-1` through `AXM-15` were locked in `0.1.0`; `AXM-16` through
`AXM-34` are added in `0.2.0` for the new `AxiomLogger` admission,
worker, default encoder, transport framing, threshold-enum, and
admission-sequence-exhaustion contracts.

## Payload contract

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `AXM-1` | Lazy host-side encoding boundary | Implicit -- the type `RemoteDeliveryEntry` carries `Data` payload bytes opaque to the engine. Every integration test in `AxiomRemoteEngineIntegrationTests` exercises this contract by enqueuing host-encoded JSON bytes. |
| `AXM-2` | JSON array request body framing (events in input order, no per-event metadata envelope, empty events => empty body) | `AxiomIngestRequestBodyTests.singleEvent`, `AxiomIngestRequestBodyTests.multipleEventsAreFramedInInputOrder`, `AxiomIngestRequestBodyTests.emptyEventsProduceEmptyBody`, `AxiomIngestRequestBodyTests.eventPayloadIsAppendedVerbatim`, `AxiomIngestRequestBodyTests.noMetadataEnvelope` |

## `RemoteTransport.sendBatch(_:)` contract

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `AXM-3` | One Axiom request per non-empty `sendBatch(_:)` call; empty batch dispatches no request | `AxiomRemoteTransportTests.sendBatchBuildsOneRequest`, `AxiomRemoteTransportTests.emptyBatchIsNoOp` |
| `AXM-4` | One result per input item | `AxiomRemoteTransportTests.sendBatchReturnsOneResultPerInputItem`, `AxiomRemoteTransportTests.emptyBatchIsNoOp` |
| `AXM-5` | Input-order preservation | `AxiomRemoteTransportTests.inputOrderingPreservedInRequestBody`, `AxiomIngestRequestBodyTests.multipleEventsAreFramedInInputOrder` |
| `AXM-6` | 2xx success projection (every item `.success`) | `AxiomRemoteTransportTests.twoXXAllSuccess`, `URLSessionAxiomIngestTransportTests.http200ReturnsResponseBodyVerbatim`, `AxiomRemoteEngineIntegrationTests.flushAllAcceptedAcknowledges` |
| `AXM-7` | Whole-batch failure projection (throw routes through `classify`) | `AxiomRemoteTransportTests.wholeBatchThrowProjectsThroughClassify`, `AxiomRemoteEngineIntegrationTests.flushTerminalItemsAcknowledges`, `AxiomRemoteEngineIntegrationTests.flushRetryableHoldsOutstandingBatch` |

## Classification policy

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `AXM-8` | Retryable mapping (408 / 429 / 5xx / invalidResponse / unknown / arbitrary error) | `AxiomRemoteTransportTests.classify408Retryable`, `AxiomRemoteTransportTests.classify429Retryable`, `AxiomRemoteTransportTests.classify5xxRetryable`, `AxiomRemoteTransportTests.classifyInvalidResponseRetryable`, `AxiomRemoteTransportTests.classifyArbitraryErrorRetryable`, `AxiomRemoteTransportTests.classifyUnknownStatusRetryable`, `URLSessionAxiomIngestTransportTests.http503ThrowsUnsuccessfulStatus`, `URLSessionAxiomIngestTransportTests.nonHTTPResponseThrowsInvalidResponse` |
| `AXM-9` | Terminal mapping (401 / 403 / other 4xx) | `AxiomRemoteTransportTests.classify401Terminal`, `AxiomRemoteTransportTests.classify403Terminal`, `AxiomRemoteTransportTests.classify400Terminal`, `URLSessionAxiomIngestTransportTests.http401ThrowsUnsuccessfulStatus` |
| `AXM-10` | Deterministic classification, no queue / export state mutation | Implicit -- `AxiomRemoteTransport.classify(_:)` is a pure function over the input `Result` (no captured queue / export references). Repeated classification invocations for the same result return the same decision; the static `classify(error:)` table-driven tests in `AxiomRemoteTransportTests` exercise the entire mapping table deterministically. Integration tests `AxiomRemoteEngineIntegrationTests.flushRetryableHoldsOutstandingBatch` and `AxiomRemoteEngineIntegrationTests.flushTerminalItemsAcknowledges` cover the engine-facing acknowledgement decision under both retryable and terminal classifications without classifier side effects. |

## Endpoint trust model

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `AXM-11` | Direct Axiom builds `Authorization: Bearer <token>`; URL is verbatim | `AxiomEndpointTests.axiomAuthorizationHeader`, `AxiomEndpointTests.axiomRequestURLIsVerbatim`, `AxiomRemoteTransportTests.directRequestCarriesBearerAuthAndJSONContentType`, `URLSessionAxiomIngestTransportTests.transportSendsPOSTWithSuppliedHeadersAndBody` |
| `AXM-12` | Intake passes Authorization verbatim or omits when `nil`; URL is verbatim | `AxiomEndpointTests.intakeAuthorizationHeaderPassthrough`, `AxiomEndpointTests.intakeNilAuthorizationOmitsHeader`, `AxiomEndpointTests.intakeRequestURLIsVerbatim`, `AxiomRemoteTransportTests.intakeRequestCarriesVerbatimAuthorization`, `AxiomRemoteTransportTests.intakeNilAuthorizationOmitsHeader` |

## Engine lifecycle ownership

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `AXM-13` | Caller-driven flush lifecycle (no autonomous scheduler) | Implicit -- the package exposes no observer / timer surface on the public engine surface; every integration test in `AxiomRemoteEngineIntegrationTests` drives `engine.flush()` from the test body. |
| `AXM-14` | Retained outstanding batch reuse across flush passes; no fresh drain while outstanding batch held | `AxiomRemoteEngineIntegrationTests.flushRetryableHoldsOutstandingBatch` |
| `AXM-15` | Acknowledgement-to-removal lifecycle (ack only on full pass-wide resolution; terminal-only still acks) | `AxiomRemoteEngineIntegrationTests.flushAllAcceptedAcknowledges`, `AxiomRemoteEngineIntegrationTests.flushTerminalItemsAcknowledges`, `AxiomRemoteEngineIntegrationTests.flushRetryableHoldsOutstandingBatch` |

## `AxiomLogger` admission and worker

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `AXM-16` | `AxiomLogger(wiring:)` constructable with default encoder and default identifier provider; accepted entry is eventually enqueued through `DurableRemoteQueue.enqueue(_:)` and `flush()` invokes engine flush | `AxiomLoggerTests.defaultConfigurationAdmitsAndFlushes`, `AxiomLoggerIntegrationTests.defaultWiringInitDeliversAdmittedEntry` |
| `AXM-17` | `LoggerLevel.disabled` drop never evaluates message or attributes and fires no diagnostic callback | `AxiomLoggerTests.disabledLevelDoesNotEvaluateClosures` |
| `AXM-18` | Below-minimum drop never evaluates message or attributes and fires no diagnostic callback | `AxiomLoggerTests.belowMinimumDoesNotEvaluateClosures` |
| `AXM-19` | Accepted entry evaluates message and attributes exactly once | `AxiomLoggerTests.acceptedEntryEvaluatesClosuresExactlyOnce` |
| `AXM-20` | `.dropNewest` drops the new entry without evaluation and fires `bufferFull(dropped: 1)` | `AxiomLoggerTests.dropNewestDoesNotEvaluateNewEntry` |
| `AXM-21` | `.dropOldest` evicts the oldest pending entry without evaluation and fires `bufferFull(dropped: 1)` | `AxiomLoggerTests.dropOldestDoesNotEvaluateEvictedEntry` |
| `AXM-22` | Encoder failure surfaces `encodingFailed(String)`; the entry is not enqueued | `AxiomLoggerTests.encodingFailureSurfacesDiagnostic` |
| `AXM-23` | Identifier failure surfaces `identifierFailed(String)`; the entry is not enqueued | `AxiomLoggerTests.identifierFailureSurfacesDiagnostic` |
| `AXM-24` | Enqueue failure surfaces `enqueueFailed(String)`; the entry is not durably admitted | `AxiomLoggerTests.enqueueFailureSurfacesDiagnostic` |
| `AXM-25` | `flush()` drains every accepted pending entry before calling the engine flush closure | `AxiomLoggerTests.flushDrainsAcceptedBeforeEngineFlush`, `AxiomLoggerTests.defaultConfigurationAdmitsAndFlushes` |
| `AXM-26` | Per-caller serial ordering preserved in worker enqueue order | `AxiomLoggerTests.perCallerOrderingPreserved` |
| `AXM-27` | Concurrent admissions never produce duplicate identifiers | `AxiomLoggerTests.concurrentAdmissionsHaveUniqueIdentifiers` |

## Default encoder

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `AXM-28` | Default encoder emits the documented `_time` / `level` / `domain` / `message` / `attributes` fields and the non-finite-`Double` stable fallback | `AxiomDefaultLogEventEncoderTests.emitsDocumentedFields`, `AxiomDefaultLogEventEncoderTests.nonFiniteDoubleFallback` |
| `AXM-29` | Default encoder redacts private and sensitive message segments through `<private>` / `<redacted>` | `AxiomDefaultLogEventEncoderTests.redactsMessageSegments` |
| `AXM-30` | Default encoder redacts private and sensitive attribute values through `<private>` / `<redacted>` | `AxiomDefaultLogEventEncoderTests.redactsAttributeValues` |
| `AXM-31` | Duplicate attribute keys resolve last-wins in the encoded attributes object | `AxiomDefaultLogEventEncoderTests.duplicateAttributeKeysLastWins` |
| `AXM-32` | Encoded payload bytes are framed verbatim by the existing Axiom transport framing helper | `AxiomLoggerTransportFramingTests.encodedPayloadIsFramedVerbatim` |
| `AXM-33` | Public `minimumLevel` is typed as the nested `AxiomLogger.MinimumLevel` enum with exactly seven `CaseIterable`, `Sendable` severities; `LoggerLevel.disabled` is not expressible as a threshold | `AxiomLoggerMinimumLevelTests.minimumLevelEnumExposesSevenSeverities` |
| `AXM-34` | Admission-sequence allocator never wraps past `UInt64.max`; exhausted admissions reject the entry without evaluating closures, without evicting any pending entry, and surface `AxiomLoggerDiagnostic.admissionSequenceExhausted` for every subsequent admission | `AxiomLoggerSequenceExhaustionTests.exhaustedSequenceRejectsAdmission`, `AxiomLoggerSequenceExhaustionTests.exhaustedSequenceFiresDiagnosticEveryAdmission` |
