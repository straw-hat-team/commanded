# OpenTelemetry SemConv Migration Plan

## Purpose

This document defines the workstreams required to align Commanded's
OpenTelemetry instrumentation with the current OpenTelemetry Semantic
Conventions (SemConv), without breaking existing users abruptly.

The goal is not to "chase docs" blindly. The goal is to:

- keep Commanded's telemetry semantically correct,
- preserve a sane migration path for downstream dashboards and alerts,
- avoid depending on gaps in the current Elixir SemConv package,
- make future SemConv updates cheaper.

## Current Situation

- Commanded depends on `opentelemetry_semantic_conventions` `1.27.0`.
- The current public OpenTelemetry SemConv docs are `1.40.0`.
- Some of the keys and values used by current SemConv are not available, or not
  exposed correctly, through the current Elixir package.
- Commanded already emits a mix of:
  - Commanded-specific attributes under `commanded.*`
  - standard OTel attributes from `OpenTelemetry.SemConv.*`
  - older/incubating messaging and code conventions
  - remote-service and endpoint attributes
  - stable error and exception attributes

## Guiding Decisions

### 1. Do not fork the SemConv registry

Commanded should not copy the whole OTel registry into the repo.

Instead, Commanded should introduce a thin compatibility layer, for example:

- `Commanded.OpenTelemetry.SemConv`

That module should:

- expose standard OTel keys and well-known values that are missing upstream,
- centralize SemConv version and migration decisions,
- keep Commanded-specific attributes separate from standard OTel ones,
- make it possible to emit legacy, new, or duplicate conventions where the spec
  explicitly recommends a migration path.

### 2. Treat SemConv changes as compatibility work, not cleanup

For some areas, especially messaging and database conventions, the SemConv docs
explicitly recommend migration support using
`OTEL_SEMCONV_STABILITY_OPT_IN`.

That means Commanded should not silently replace old attributes in one patch
release if doing so would break existing users.

### 3. Keep service identity at the resource boundary

`service.name` and `service.namespace` should describe the logical deployed
service or worker, not individual Commanded handlers, aggregates, or projectors.

Handler and aggregate identity should be modeled at span level using span names,
code attributes, messaging attributes where appropriate, and `commanded.*`
attributes.

## Relevant SemConv Applicability Matrix

This plan focuses on all SemConv areas that are relevant to Commanded's current
instrumentation surface or that directly constrain the migration decisions.

### 1. Resource Service Identity

Status:

- relevant
- not emitted directly by Commanded spans today
- architecture-defining for naming decisions

Relevant docs:

- `https://opentelemetry.io/docs/specs/semconv/registry/attributes/service/`

Important points:

- `service.name` and `service.namespace` are resource-level identity.
- They should describe the deployed service or worker, not an internal handler,
  aggregate, or projector.
- `service.instance.id` remains the instance-level identifier.

Impact on Commanded:

- This constrains how Commanded names handlers and spans.
- It confirms that Commanded should not invent per-handler `service.*`
  identities.

### 2. Messaging

Relevant docs:

- `https://opentelemetry.io/docs/specs/semconv/messaging/`
- `https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/`

Important points:

- Messaging conventions are still marked `Development`.
- Existing instrumentations using older messaging SemConv should not change
  their default emitted conventions immediately.
- The migration path should support:
  - `messaging`
  - `messaging/dup`
- Current well-known operation types are:
  - `create`
  - `send`
  - `receive`
  - `process`
  - `settle`
- Span kind must align with operation type:
  - `create -> PRODUCER`
  - `send -> PRODUCER` or `CLIENT`
  - `receive -> CLIENT`
  - `process -> CONSUMER`
  - `settle -> CLIENT`
- `messaging.destination.name` should represent an actual messaging destination,
  not an arbitrary internal module name.

Impact on Commanded:

- `application`, `aggregate`, and `event_handler` spans currently use messaging
  attributes.
- Several spans use operation types and span kinds that do not match current
  SemConv.
- Handler and aggregate module names are currently being written into
  `messaging.destination.name`, which is not a good semantic fit.

### 3. Database

Relevant docs:

- `https://opentelemetry.io/docs/specs/semconv/db/`
- `https://opentelemetry.io/docs/specs/semconv/database/database-spans/`
- `https://opentelemetry.io/docs/specs/semconv/non-normative/db-migration/`

Important points:

- Database client span SemConv is stable.
- Existing instrumentations using older database conventions should support:
  - `database`
  - `database/dup`
- Stable conventions include names such as:
  - `db.system.name`
  - `db.operation.name`
  - `db.namespace`
- Older `db.system` is legacy.

Impact on Commanded:

- `event_store` spans currently use database-related attributes only partially.
- Connection metadata handling should be reviewed against stable database and
  general remote-service conventions.

### 4. Code Attributes

Relevant docs:

- `https://opentelemetry.io/docs/specs/semconv/non-normative/code-attrs-migration/`
- `https://opentelemetry.io/docs/specs/semconv/registry/attributes/code/`

Important points:

- `code.function` and `code.namespace` are deprecated.
- `code.function.name` is the stable replacement.
- `code.function.name` should be fully-qualified and should match the natural
  representation of the runtime.

Impact on Commanded:

- Commanded still emits the removed pair `code.function` and `code.namespace`
  across the current instrumentation modules.

### 5. Error Attributes

Relevant docs:

- `https://opentelemetry.io/docs/specs/semconv/attributes-registry/error/`

Important points:

- `error.type` is stable.
- `error.message` exists but is not generally recommended for spans due to
  cardinality and overlap with span status.
- Instrumentations should keep `error.type` low-cardinality and predictable.

Impact on Commanded:

- Commanded already uses `error.type`.
- The migration work must preserve the current good parts here while other
  SemConv areas change.

### 6. Exception Attributes and Exception Signal Conventions

Relevant docs:

- `https://opentelemetry.io/docs/specs/semconv/exceptions/`
- `https://opentelemetry.io/docs/specs/semconv/registry/attributes/exception/`

Important points:

- `exception.type`, `exception.message`, and `exception.stacktrace` remain
  stable attributes for exception records.
- Existing instrumentations that record exceptions on spans are now covered by a
  separate migration path around `OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN`.
- The current default for existing instrumentations is to continue recording
  exceptions as span events unless the instrumentation intentionally adds the
  new logs migration behavior.

Impact on Commanded:

- Commanded records exceptions with `Span.record_exception/3` today.
- Even if we do not migrate exception signals immediately, this is a relevant
  SemConv area and should be acknowledged in the plan.

### 7. Remote Service Naming

Relevant docs:

- `https://opentelemetry.io/docs/specs/semconv/registry/attributes/peer/`
- `https://opentelemetry.io/docs/specs/semconv/general/attributes/`

Important points:

- `peer.service` is deprecated.
- `service.peer.name` is the modern replacement.
- `service.peer.name` is currently `Development` / `Opt-In`.

Impact on Commanded:

- `peer.service` is still emitted for event store connection metadata.
- This replacement should be handled through the compatibility layer rather than
  treated as a blind stable swap.

### 8. Server and Shared Network Endpoint Attributes

Relevant docs:

- `https://opentelemetry.io/docs/specs/semconv/registry/attributes/server/`
- `https://opentelemetry.io/docs/specs/semconv/general/attributes/`

Important points:

- `server.address` and `server.port` are stable and relevant to client-side
  spans that connect to a remote service.
- `network.*` attributes also exist, but Commanded does not currently emit
  them.

Impact on Commanded:

- `event_store` spans currently emit `server.address` and `server.port`.
- We should decide whether the current `server.*` coverage is sufficient or
  whether any additional stable network attrs are worth adding later.

### 9. General Attribute Registry and Custom Attribute Discipline

Relevant docs:

- `https://opentelemetry.io/docs/specs/semconv/registry/attributes/`

Important points:

- Standard attributes should come from the registry when applicable.
- Custom attributes are appropriate where no standard semantic exists, but they
  should not shadow or distort existing standard meanings.

Impact on Commanded:

- This is the justification for keeping `commanded.*` in its own module and
  moving standard OTel compatibility decisions into a dedicated
  `Commanded.OpenTelemetry.SemConv` module.

## Current Instrumentation Surface

The current OpenTelemetry instrumentation lives primarily in:

- `lib/commanded/opentelemetry/application.ex`
- `lib/commanded/opentelemetry/aggregate.ex`
- `lib/commanded/opentelemetry/aggregate_populate.ex`
- `lib/commanded/opentelemetry/aggregate_snapshot.ex`
- `lib/commanded/opentelemetry/event_handler.ex`
- `lib/commanded/opentelemetry/event_store.ex`
- `lib/commanded/opentelemetry/helpers.ex`
- `lib/commanded/opentelemetry/commanded_attributes.ex`

The current test surface lives primarily in:

- `test/opentelemetry/application_test.exs`
- `test/opentelemetry/aggregate_test.exs`
- `test/opentelemetry/aggregate_populate_test.exs`
- `test/opentelemetry/aggregate_snapshot_test.exs`
- `test/opentelemetry/event_handler_test.exs`
- `test/opentelemetry/event_store_test.exs`

The main user-facing guide is:

- `guides/howtos/setting-up-opentelemetry-tracing.md`

## Known Mismatches To Address

The following are the major issues already identified and should be treated as
the initial backlog for the migration work:

1. Commanded emits deprecated code attributes:
   - `code.function`
   - `code.namespace`

2. Messaging operation values and span kinds are not always aligned with the
   current SemConv model.

3. `messaging.destination.name` is used for handler or aggregate module names,
   which does not represent a real messaging destination.

4. `peer.service` is still emitted instead of `service.peer.name`.

5. The current Elixir SemConv package does not expose the full current key set,
   so direct package helpers are not enough.

6. Exception SemConv is relevant because Commanded emits exception span events,
   but the original plan did not spell out the newer exception-signal migration
   path.

7. Tests currently assert older keys and values, so the existing behavior is not
   merely accidental; it is part of the current public behavior.

## Proposed Architecture

### New Compatibility Module

Add a central module:

- `lib/commanded/opentelemetry/sem_conv.ex`

Responsibilities:

- expose standard OTel attribute keys,
- expose well-known low-cardinality values,
- normalize missing or renamed attributes,
- own compatibility logic for SemConv migrations,
- parse `OTEL_SEMCONV_STABILITY_OPT_IN`,
- support category-specific behavior for:
  - `messaging`
  - `database`
  - optionally `exceptions`
  - optionally `code`

The module should not contain Commanded-specific attributes.

### Existing Commanded Attributes Module

Keep:

- `lib/commanded/opentelemetry/commanded_attributes.ex`

Responsibilities:

- only `commanded.*` keys,
- no standard OTel compatibility logic,
- no SemConv migration mode logic.

## Workstreams

### Workstream 1: Build the SemConv Compatibility Layer

Objective:

- create the foundation that makes every later migration straightforward.

Deliverables:

- `Commanded.OpenTelemetry.SemConv`
- a small API for:
  - current mode lookup,
  - attribute key lookup,
  - operation-type values,
  - span-name helpers where useful,
  - dual-emission helpers where the spec recommends it

Decisions to settle:

- whether mode resolution is fully dynamic from environment variables or cached
  at setup time,
- whether code SemConv migration should also support `code` / `code/dup`, or
  whether Commanded should move directly to the stable code keys.

Acceptance criteria:

- no instrumentation module reaches directly for hard-coded legacy-vs-new
  decisions,
- migration behavior is centralized in one place.

### Workstream 2: Migrate Code Attributes

Objective:

- replace deprecated code attrs with stable ones.

Deliverables:

- move from:
  - `code.function`
  - `code.namespace`
- to:
  - `code.function.name`

Implementation notes:

- For Elixir, the value should be naturally represented and fully-qualified.
- Prefer values like:
  - `MyApp.Handler.handle`
  - `MyApp.AccountAggregate.execute`
- Avoid storing split namespace/function data once the stable key exists.

Acceptance criteria:

- all instrumentation modules emit stable code attrs,
- tests assert the stable key,
- docs no longer show the deprecated pair.

### Workstream 3: Migrate Messaging SemConv Safely

Objective:

- correct the messaging model without breaking users unexpectedly.

Deliverables:

- support for:
  - legacy behavior by default
  - `OTEL_SEMCONV_STABILITY_OPT_IN=messaging`
  - `OTEL_SEMCONV_STABILITY_OPT_IN=messaging/dup`

Main questions to resolve:

- Which Commanded spans should remain modeled as messaging spans at all?
- Which spans are better represented as internal library spans with
  `commanded.*` and code attrs only?

Specific review targets:

- `application` dispatch span
- `aggregate` execute span
- `event_handler` handle span
- `event_handler` batch span
- `aggregate_populate` load/populate spans
- `aggregate_snapshot` snapshot span

Expected corrections:

- `event_handler` handling is much closer to `process` + `CONSUMER` than
  `receive` + `CONSUMER`.
- `application` and `aggregate` likely need the same review.
- `publish` should be replaced by the current well-known value where applicable.
- `messaging.destination.name` should only be emitted when there is a true,
  low-cardinality destination.

Acceptance criteria:

- each messaging span has a justified operation type,
- each messaging span kind matches the current spec,
- destination-related attributes are no longer overloaded with internal module
  names,
- duplicate or migration emission works as designed.

### Workstream 4: Re-evaluate Which Spans Should Use Messaging At All

Objective:

- avoid forcing internal Commanded lifecycle spans into messaging semantics when
  the fit is weak.

Why this is separate:

- some current spans look like "message processing",
- others look more like library internal operations that happen in response to
  earlier message handling,
- trying to express everything as messaging can produce invalid or misleading
  telemetry.

Likely outcomes:

- `event_handler` spans may remain messaging-shaped,
- `application` dispatch and `aggregate` execute may need either:
  - a refined messaging interpretation, or
  - a move toward internal spans with stronger `commanded.*` and code attrs.

Acceptance criteria:

- every span has a clear semantic model,
- we stop using messaging attrs where they exist only because we had no better
  bucket earlier.

### Workstream 5: Migrate Event Store Spans Toward Stable Database/Remote Service Conventions

Objective:

- align event store spans with stable database and remote service conventions.

Deliverables:

- support for:
  - legacy database behavior by default if required
  - `database`
  - `database/dup`
- replace deprecated peer naming

Specific review targets:

- `db.system` vs `db.system.name`
- `db.namespace`
- `service.peer.name`
- whether current span names should change under opt-in mode

Acceptance criteria:

- event store spans emit modern remote-service naming,
- database attributes are stable under the new mode,
- migration path mirrors SemConv guidance.

### Workstream 6: Review Exception Signal Migration

Objective:

- explicitly decide whether Commanded should remain span-event-only for
  exceptions for now, or whether it should support
  `OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN`.

Why this matters:

- Commanded already emits exception span events today.
- The latest SemConv now treats exception signal migration as its own concern,
  separate from messaging and database migrations.

Likely near-term outcome:

- keep current behavior for now,
- document the decision,
- avoid accidental incompatibility if we later decide to support exception logs.

Acceptance criteria:

- the plan explicitly accounts for the exception SemConv path,
- we make an intentional choice rather than inheriting behavior by omission.

### Workstream 7: Update Tests To Reflect Compatibility Modes

Objective:

- stop treating one single SemConv shape as the only valid shape during the
  migration window.

Deliverables:

- tests for:
  - default legacy behavior
  - opt-in new behavior
  - duplicate emission behavior where applicable
  - explicit exception behavior where relevant

Notes:

- this is critical for messaging and database changes,
- otherwise every SemConv migration will keep looking like a breaking test
  failure rather than an intentional compatibility change.

Acceptance criteria:

- test names make the mode explicit,
- tests verify span names, span kind, and attrs by mode,
- downstream regressions can be detected without pinning Commanded permanently to
  the legacy shape.

### Workstream 8: Update User Documentation

Objective:

- explain the migration in operational terms, not internal implementation terms.

Deliverables:

- update `guides/howtos/setting-up-opentelemetry-tracing.md`
- document:
  - current defaults,
  - `OTEL_SEMCONV_STABILITY_OPT_IN`,
  - what changes under `messaging`,
  - what changes under `database`,
  - what Commanded does about exception SemConv,
  - whether `code` migration is configurable or unconditional

Acceptance criteria:

- users can intentionally opt into the new SemConv without guessing,
- docs clearly distinguish Commanded custom attrs from standard OTel attrs.

### Workstream 9: Release and Compatibility Strategy

Objective:

- decide how this ships without surprising users.

Recommended strategy:

1. Introduce the compatibility layer first.
2. Keep legacy behavior as default for the SemConv areas where the spec requires
   migration support.
3. Add opt-in modes and duplicate-emission support.
4. Update docs and tests.
5. Consider flipping defaults only in the next major release, if still needed.

Acceptance criteria:

- the release notes can explain the migration in one page,
- downstream users have a clear path to validate dashboards before a major
  version switch.

## Proposed Execution Order

This should be done in small, reviewable changes rather than one large branch.

### Phase 1

- add `Commanded.OpenTelemetry.SemConv`
- centralize key/value helpers
- do not change emitted behavior yet unless required for internal refactor

### Phase 2

- migrate code attrs to `code.function.name`
- update tests for code attrs
- update docs if this is unconditional

### Phase 3

- add messaging compatibility modes
- migrate `event_handler` first
- then migrate `application` and `aggregate`
- then decide whether `aggregate_populate` and `aggregate_snapshot` should stay
  messaging-shaped

### Phase 4

- add database compatibility modes for `event_store`
- replace `peer.service`
- align event store span naming and attrs

### Phase 5

- review exception signal behavior and document the decision
- update tests for all compatibility modes
- verify end-to-end emitted spans across modes

### Phase 6

- clean up docs
- add migration notes

## Suggested PR Breakdown

To keep review quality high, split the work into separate PRs:

1. `refactor(telemetry): centralize SemConv compatibility decisions`
2. `fix(telemetry): migrate Commanded code attributes to stable SemConv`
3. `feat(telemetry): add messaging SemConv opt-in compatibility`
4. `fix(telemetry): correct event handler messaging semantics`
5. `fix(telemetry): align event store spans with stable database conventions`
6. `docs(telemetry): document exception SemConv decision`
7. `docs(telemetry): document SemConv compatibility modes`

The exact split may change, but the important constraint is: do not couple code,
messaging, database, and docs migration into one review.

## Open Questions

These need to be answered during implementation, not hand-waved:

1. Should `application` dispatch spans stay modeled as messaging, or should they
   become internal spans with stronger code and `commanded.*` semantics?

2. Should `aggregate` execute spans stay modeled as messaging, or are they
   better treated as internal command-processing spans?

3. Should code SemConv migration support `code` / `code/dup`, or can Commanded
   move directly to stable code attrs because the old attrs are already
   deprecated and structurally replaced?

4. What should Commanded use as `messaging.destination.name`, if anything, for
   handler and aggregate spans?

5. Do we want a small helper API for fully-qualified Elixir function naming so
   `code.function.name` is emitted consistently everywhere?

6. Should Commanded support `OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN`, or is that
   outside the intended responsibility of this library for now?

## Out of Scope

This plan does not currently include:

- metrics migration beyond what is required for the spans already emitted here,
- broad logs SemConv work beyond the exception-signal review noted above,
- resource detection or exporter configuration outside Commanded's own
  instrumentation,
- changing user application resource attributes such as `service.name` or
  `service.namespace`

## Definition of Done

This migration is complete when:

- standard OTel attrs emitted by Commanded are explainable against current
  SemConv docs,
- all SemConv compatibility decisions live in one place,
- messaging and database migrations support the documented compatibility path,
- exception behavior is intentionally documented,
- tests cover legacy, new, and duplicate emission where relevant,
- user docs describe the migration clearly,
- downstream users are not forced into a silent telemetry schema break.

## Reference Docs

- `https://opentelemetry.io/docs/specs/semconv/`
- `https://opentelemetry.io/docs/specs/semconv/registry/attributes/`
- `https://opentelemetry.io/docs/specs/semconv/messaging/`
- `https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/`
- `https://opentelemetry.io/docs/specs/semconv/db/`
- `https://opentelemetry.io/docs/specs/semconv/database/database-spans/`
- `https://opentelemetry.io/docs/specs/semconv/non-normative/db-migration/`
- `https://opentelemetry.io/docs/specs/semconv/non-normative/code-attrs-migration/`
- `https://opentelemetry.io/docs/specs/semconv/exceptions/`
- `https://opentelemetry.io/docs/specs/semconv/attributes-registry/error/`
- `https://opentelemetry.io/docs/specs/semconv/registry/attributes/exception/`
- `https://opentelemetry.io/docs/specs/semconv/registry/attributes/code/`
- `https://opentelemetry.io/docs/specs/semconv/registry/attributes/peer/`
- `https://opentelemetry.io/docs/specs/semconv/registry/attributes/server/`
- `https://opentelemetry.io/docs/specs/semconv/general/attributes/`
- `https://opentelemetry.io/docs/specs/semconv/registry/attributes/service/`
