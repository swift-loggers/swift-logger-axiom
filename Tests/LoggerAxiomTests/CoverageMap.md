# Coverage map -- `swift-logger-axiom 0.2.0`

Each requirement ID locked in
[`Docs/Requirements.md`](../../Docs/Requirements.md) maps to the
test (or tests) that enforce it.

`AXM-1` through `AXM-15` shipped in `0.1.0`; `AXM-16` through
`AXM-45` ship in `0.2.0` for the `AxiomLogger` admission, worker,
default encoder, transport framing, threshold-enum, and
admission-sequence-exhaustion contracts plus the new
`AxiomLoggingService` flush coordinator.

## Payload contract

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `AXM-1` | Lazy host-side encoding boundary | Implicit (public API invariant) -- the type `RemoteDeliveryEntry` carries `Data` payload bytes opaque to the engine. Every integration test in `AxiomRemoteEngineIntegrationTests` exercises this contract by enqueuing host-encoded JSON bytes. |
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
| `AXM-10` | Deterministic classification, no queue / export state mutation | Implicit (purity invariant) -- `AxiomRemoteTransport.classify(_:)` is a pure function over the input `Result` (no captured queue / export references). Repeated classification invocations for the same result return the same decision; the static `classify(error:)` table-driven tests in `AxiomRemoteTransportTests` exercise the entire mapping table deterministically. Integration tests `AxiomRemoteEngineIntegrationTests.flushRetryableHoldsOutstandingBatch` and `AxiomRemoteEngineIntegrationTests.flushTerminalItemsAcknowledges` cover the engine-facing acknowledgement decision under both retryable and terminal classifications without classifier side effects. |

## Endpoint trust model

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `AXM-11` | Direct Axiom builds `Authorization: Bearer <token>`; URL is verbatim | `AxiomEndpointTests.axiomAuthorizationHeader`, `AxiomEndpointTests.axiomRequestURLIsVerbatim`, `AxiomRemoteTransportTests.directRequestCarriesBearerAuthAndJSONContentType`, `URLSessionAxiomIngestTransportTests.transportSendsPOSTWithSuppliedHeadersAndBody` |
| `AXM-12` | Intake passes Authorization verbatim or omits when `nil`; URL is verbatim | `AxiomEndpointTests.intakeAuthorizationHeaderPassthrough`, `AxiomEndpointTests.intakeNilAuthorizationOmitsHeader`, `AxiomEndpointTests.intakeRequestURLIsVerbatim`, `AxiomRemoteTransportTests.intakeRequestCarriesVerbatimAuthorization`, `AxiomRemoteTransportTests.intakeNilAuthorizationOmitsHeader` |

## Engine lifecycle ownership

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `AXM-13` | Caller-driven flush lifecycle (no autonomous scheduler) | Implicit (architectural invariant) -- the remote engine itself exposes no autonomous scheduler, observer, or timer surface; every integration test in `AxiomRemoteEngineIntegrationTests` drives `engine.flush()` from the test body. |
| `AXM-14` | Retained outstanding batch reuse across flush passes; no fresh drain while outstanding batch held | `AxiomRemoteEngineIntegrationTests.flushRetryableHoldsOutstandingBatch` |
| `AXM-15` | Acknowledgement-to-removal lifecycle (ack only on full pass-wide resolution; terminal-only still acks) | `AxiomRemoteEngineIntegrationTests.flushAllAcceptedAcknowledges`, `AxiomRemoteEngineIntegrationTests.flushTerminalItemsAcknowledges`, `AxiomRemoteEngineIntegrationTests.flushRetryableHoldsOutstandingBatch` |

## `AxiomLogger` admission and worker

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `AXM-16` | `AxiomLogger(wiring:)` constructable with default encoder and default identifier provider;<br>accepted entry is eventually enqueued through `DurableRemoteQueue.enqueue(_:)`;<br>`flush()` invokes engine flush | `AxiomLoggerTests.defaultConfigurationAdmitsAndFlushes`, `AxiomLoggerIntegrationTests.defaultWiringInitDeliversAdmittedEntry` |
| `AXM-17` | `LoggerLevel.disabled` drop never evaluates message or attributes and fires no diagnostic callback | `AxiomLoggerTests.disabledLevelDoesNotEvaluateClosures` |
| `AXM-18` | Below-minimum drop never evaluates message or attributes and fires no diagnostic callback | `AxiomLoggerTests.belowMinimumDoesNotEvaluateClosures` |
| `AXM-19` | Accepted entry evaluates message and attributes exactly once | `AxiomLoggerTests.acceptedEntryEvaluatesClosuresExactlyOnce` |
| `AXM-20` | `.dropNewest` drops the new entry without evaluation and fires `bufferFull(dropped: 1)` | `AxiomLoggerTests.dropNewestDoesNotEvaluateNewEntry` |
| `AXM-21` | `.dropOldest` evicts the oldest pending entry without evaluation and fires `bufferFull(dropped: 1)` | `AxiomLoggerTests.dropOldestDoesNotEvaluateEvictedEntry` |
| `AXM-22` | Encoder failure surfaces `encodingFailed(String)`; the entry is not enqueued | `AxiomLoggerTests.encodingFailureSurfacesDiagnostic` |
| `AXM-23` | Identifier failure surfaces `identifierFailed(String)`; the entry is not enqueued | `AxiomLoggerTests.identifierFailureSurfacesDiagnostic` |
| `AXM-24` | Enqueue failure surfaces `enqueueFailed(String)`; the entry is not durably admitted | `AxiomLoggerTests.enqueueFailureSurfacesDiagnostic` |
| `AXM-25` | `flush()` drains every accepted pending entry;<br>engine flush starts only after the drain completes | `AxiomLoggerTests.flushDrainsAcceptedBeforeEngineFlush`, `AxiomLoggerTests.defaultConfigurationAdmitsAndFlushes` |
| `AXM-26` | Per-caller serial admission ordering is preserved in worker enqueue order | `AxiomLoggerTests.perCallerOrderingPreserved` |
| `AXM-27` | Concurrent admissions never produce duplicate identifiers | `AxiomLoggerTests.concurrentAdmissionsHaveUniqueIdentifiers` |

## Default encoder

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `AXM-28` | Default encoder emits the documented `_time` / `level` / `domain` / `message` / `attributes` fields;<br>non-finite `Double` attribute values emit stable fallback encoding | `AxiomDefaultLogEventEncoderTests.emitsDocumentedFields`, `AxiomDefaultLogEventEncoderTests.nonFiniteDoubleFallback` |
| `AXM-29` | Default encoder redacts private and sensitive message segments through `<private>` / `<redacted>` | `AxiomDefaultLogEventEncoderTests.redactsMessageSegments` |
| `AXM-30` | Default encoder redacts private and sensitive attribute values through `<private>` / `<redacted>` | `AxiomDefaultLogEventEncoderTests.redactsAttributeValues` |
| `AXM-31` | Duplicate attribute keys resolve last-wins in the encoded attributes object | `AxiomDefaultLogEventEncoderTests.duplicateAttributeKeysLastWins` |
| `AXM-32` | Encoded payload bytes are framed verbatim by the existing Axiom transport framing helper without additional logger-side metadata envelope or wrapping | `AxiomLoggerTransportFramingTests.encodedPayloadIsFramedVerbatim` |
| `AXM-33` | Public `minimumLevel` is typed as the nested `AxiomLogger.MinimumLevel` enum with exactly seven `CaseIterable`, `Sendable` severities; `LoggerLevel.disabled` is not expressible as a threshold | `AxiomLoggerMinimumLevelTests.minimumLevelEnumExposesSevenSeverities` |
| `AXM-34` | Admission-sequence allocator never wraps past `UInt64.max`;<br>exhausted admissions reject the entry without evaluating closures or evicting pending entries;<br>every subsequent exhausted admission surfaces `AxiomLoggerDiagnostic.admissionSequenceExhausted` | `AxiomLoggerSequenceExhaustionTests.exhaustedSequenceRejectsAdmission`, `AxiomLoggerSequenceExhaustionTests.exhaustedSequenceFiresDiagnosticEveryAdmission` |

## `AxiomLoggingService`

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `AXM-35` | `start()` is idempotent; repeated calls launch a single internal periodic loop | `AxiomLoggingServiceTests.startIsIdempotent` |
| `AXM-36` | `AxiomFlushPolicy.manual` starts no periodic loop; the only flushes the service drives are explicit `flush()` and the final flush in `stop()` | `AxiomLoggingServiceTests.manualPolicyDoesNotFlushPeriodically` |
| `AXM-37` | `AxiomFlushPolicy.periodic(seconds:)` starts one internal periodic loop that drives `AxiomLogger.flush()` | `AxiomLoggingServiceTests.periodicPolicyDrivesFlushes` |
| `AXM-38` | Periodic flushes are serially scheduled in a single internal task; two periodic flushes never overlap | `AxiomLoggingServiceTests.periodicFlushesAreSerial` |
| `AXM-39` | `AxiomLoggingService.flush()` forwards to `AxiomLogger.flush()` and returns the resulting `RemoteFlushSummary` or rethrows the underlying error | `AxiomLoggingServiceTests.flushForwardsSummary`, `AxiomLoggingServiceTests.flushRethrowsError` |
| `AXM-40` | `AxiomLoggingService.stop()` cancels the periodic loop;<br>awaits periodic-loop exit;<br>performs exactly one final `AxiomLogger.flush()`;<br>concurrent and subsequent calls join the in-flight stop and return only after it completes | `AxiomLoggingServiceTests.stopCancelsPeriodicLoop`, `AxiomLoggingServiceTests.stopPerformsFinalFlush`, `AxiomLoggingServiceTests.concurrentStopWaitsForFinalFlush` |
| `AXM-41` | A throw from the periodic flush surfaces `AxiomLoggingServiceDiagnostic.flushFailed(_:)`; the periodic loop continues | `AxiomLoggingServiceTests.periodicFailureSurfacesDiagnostic` |
| `AXM-42` | A throw from the final flush inside `stop()` surfaces `AxiomLoggingServiceDiagnostic.flushFailed(_:)` instead of re-throwing | `AxiomLoggingServiceTests.stopFinalFlushFailureSurfacesDiagnostic` |
| `AXM-43` | `AxiomLoggingService` introduces no UIKit / AppKit / SwiftUI / WatchKit dependency | `AxiomLoggingServiceTests.serviceFamilyDeclaresNoPlatformImport` |
| `AXM-44` | A non-positive, non-finite, or sub-nanosecond `.periodic(seconds:)` interval does not start a periodic loop;<br>surfaces `AxiomLoggingServiceDiagnostic.invalidFlushInterval(seconds:)`;<br>behaves as `.manual` thereafter | `AxiomLoggingServiceBoundaryTests.invalidPeriodicIntervalDoesNotStartLoop`, `AxiomLoggingServiceBoundaryTests.nanPeriodicIntervalDoesNotStartLoop`, `AxiomLoggingServiceBoundaryTests.subNanosecondPeriodicIntervalIsRejected` |
| `AXM-45` | Deallocating an `AxiomLoggingService` cancels its periodic loop; cancellation prevents any further loop iteration, but a flush already in flight when deallocation runs completes on its own | `AxiomLoggingServiceBoundaryTests.deinitCancelsPeriodicLoop` |
