# Built-in vs External Ecto Projections

This document explains the differences between Commanded's built-in Ecto projections and the external `commanded-ecto-projections` package, helping you understand the design decisions and trade-offs.

**See also:** [How to Migrate Guide](../howtos/migrating-from-commanded-ecto-projections.md)

## Why Built-in Support Exists

The `commanded-ecto-projections` package was originally created as an external library to provide Ecto integration for Commanded. In version 1.4, this functionality was integrated directly into Commanded core for several reasons:

### Maintenance and Integration

**External Package Challenges:**
- Separate release cycle from Commanded core
- Version compatibility management overhead
- Duplicate issue tracking across repositories
- Integration testing complexity

**Built-in Benefits:**
- Single dependency to manage
- Guaranteed compatibility with Commanded features
- Unified issue tracking and support
- Better compile-time validation

### Feature Development

With built-in support, new features can be developed holistically:

- Batch processing was added with deep integration into the event handler system
- Compile-time validation catches configuration errors early
- Better error messages with context from both systems
- Seamless integration with Commanded's telemetry

## Compatibility Analysis

### Fully Compatible Features

These features work identically between both implementations:

**Core Projection API:**
- `project/2` and `project/3` macros use the same syntax
- Pattern matching on events works identically
- `Ecto.Multi` composition is unchanged
- Transaction semantics are preserved

**Callbacks:**
- `after_update/3` callback signature and behavior
- `error/3` error handling callback
- Lifecycle hooks function identically

**Configuration:**
- `:consistency` option (`:strong` or `:eventual`)
- `:start_from` option for replay control
- `:subscribe_to` for stream selection
- `:name` for projection identification

**Multi-tenancy:**
- `schema_prefix/1` and `schema_prefix/2` callbacks
- PostgreSQL schema isolation
- Dynamic schema resolution per event

**Idempotency:**
- Watermark-based tracking mechanism
- `projection_versions` table structure
- Event ordering guarantees

### The One Breaking Change: Concurrency

The only breaking change is the removal of the `:concurrency` option.

**Why It Was Removed:**

The external package allowed:

```elixir
use Commanded.Projections.Ecto,
  concurrency: 10  # Multiple concurrent workers
```

This configuration had a critical flaw that could cause silent data loss.

**The Problem:**

With watermark-based idempotency, concurrent workers can process events out of order:

```
Timeline:
T1: Worker A receives Event #5
T2: Worker B receives Event #3
T3: Worker B completes, updates watermark to 3
T4: Worker A completes, updates watermark to 5
T5: Event #4 arrives
T6: Event #4 is skipped (4 < 5) ❌ DATA LOSS
```

Event #4 is permanently lost because the watermark jumped from 3 to 5.

**Why Regular Event Handlers Can Use Concurrency:**

Regular `Commanded.Event.Handler` modules don't use watermark idempotency. They rely on the event store's checkpoint mechanism and use `partition_by/2` to guarantee per-partition ordering while allowing cross-partition concurrency.

**The Built-in Solution:**

Instead of concurrency, use batch processing:

```elixir
use Commanded.Projections.Ecto,
  batch_size: 100  # Process 100 events per transaction
```

Batch processing provides:
- ✅ High throughput (10-50x faster than single-event processing)
- ✅ Ordering guarantees (no data loss)
- ✅ Safe with watermark idempotency
- ✅ Simpler mental model

## New Features in Built-in Support

### Batch Processing

Process multiple events in a single database transaction:

```elixir
defmodule MyApp.BatchProjector do
  use Commanded.Projections.Ecto,
    batch_size: 100

  project_batch fn events, multi ->
    Enum.reduce(events, multi, fn {event, metadata}, multi ->
      # Process event
    end)
  end
end
```

**Benefits:**
- Reduced transaction overhead
- Single fsync for multiple events
- Higher throughput for high-volume streams

### Compile-Time Validation

The built-in implementation validates configuration at compile time:

```elixir
# ❌ Compile error with helpful message
use Commanded.Projections.Ecto,
  concurrency: 10  # Error: concurrency not supported, use batch_size
```

The external package allowed invalid configurations that would cause runtime issues.

### Better Error Messages

Built-in support provides context-aware error messages:

```
** (Commanded.Projections.Ecto.ProjectionError) 
   Projection "account_projector" failed to process event #1234
   
   Event: %AccountOpened{account_id: "abc"}
   Reason: unique constraint violation on accounts.id
   
   This is likely a duplicate event. Check your idempotency handling.
```

The external package had generic Ecto errors without projection context.

### Enhanced Telemetry

Projection events are integrated into Commanded's telemetry system:

```elixir
[:commanded, :projection, :handle, :start]
[:commanded, :projection, :handle, :stop]
[:commanded, :projection, :handle, :exception]
```

This provides better observability and monitoring capabilities.

## Design Philosophy Differences

### External Package Philosophy

The external package prioritized flexibility:
- Allow configurations even if potentially unsafe
- Let users make their own performance decisions
- Minimal validation and constraints

This led to:
- ✅ More configuration options
- ❌ Silent failure modes
- ❌ Potential data loss scenarios

### Built-in Philosophy

The built-in implementation prioritizes correctness:
- Prevent configurations that can cause data loss
- Fail fast with clear error messages
- Guide users toward safe patterns

This leads to:
- ✅ Fewer ways to shoot yourself in the foot
- ✅ Better developer experience
- ❌ Slightly less flexibility

## Migration Path Design

The migration path was designed to be as painless as possible:

**What didn't change:**
- Core projection API
- Module and function names
- Callback signatures
- Database schema

**What did change:**
- Concurrency option removed (replaced with batch_size)

This means:
- ✅ Most projections need zero code changes
- ✅ No database migrations required
- ✅ Gradual migration possible
- ✅ Easy rollback if needed

## When to Use Each

### Use Built-in Support When:

- ✅ Starting a new Commanded project
- ✅ You want the latest features (batch processing)
- ✅ You value safety over flexibility
- ✅ You want unified support and documentation
- ✅ You're migrating from concurrency to batching anyway

### Stick with External Package When:

- ⚠️ You have a critical dependency on concurrency > 1
- ⚠️ You can't modify your projection code immediately
- ⚠️ You're on an older Commanded version (< 1.4)

**Note:** The external package is in maintenance mode. New features will only be added to built-in support.

## Performance Comparison

Both implementations have similar performance characteristics for equivalent configurations:

**External with concurrency: 1**
```elixir
use Commanded.Projections.Ecto, concurrency: 1
# ~500 events/second
```

**Built-in without batching**
```elixir
use Commanded.Projections.Ecto
# ~500 events/second (equivalent)
```

**External with concurrency: 10** (unsafe)
```elixir
use Commanded.Projections.Ecto, concurrency: 10
# ~2,000 events/second (but with data loss risk)
```

**Built-in with batch processing** (safe)
```elixir
use Commanded.Projections.Ecto, batch_size: 100
# ~5,000-10,000 events/second (safe and faster)
```

Batch processing achieves better throughput than concurrency without the data loss risk.

## Implementation Details

### Idempotency Mechanism

Both implementations use the same watermark-based idempotency:

```sql
CREATE TABLE projection_versions (
  projection_name TEXT PRIMARY KEY,
  last_seen_event_number BIGINT NOT NULL,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);
```

The mechanism:
1. Lock projection version row (`FOR UPDATE`)
2. Check if event_number > last_seen_event_number
3. If true, process event and update watermark
4. If false, skip event (already processed)

This is why concurrency doesn't work: multiple workers can update the watermark out of order.

### Transaction Handling

Both implementations use the same transaction pattern:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.run(:projection_version, fn -> lock_and_check() end)
|> Ecto.Multi.insert(:my_data, changeset)  # Your projection
|> Repo.transaction()
```

If any step fails, the entire transaction rolls back.

## Future Direction

The built-in implementation will continue to evolve with Commanded:

**Planned features:**
- Projection health checks
- Automatic rebuild capabilities
- Enhanced monitoring tools
- Performance optimizations

**Not planned:**
- Concurrency support (fundamentally incompatible with watermark idempotency)
- Alternative idempotency mechanisms (adds complexity)

The external package will remain available for legacy projects but won't receive new features.

## Summary

**Built-in Ecto projections:**
- ✅ Safer (prevents data loss configurations)
- ✅ Better performance (batch processing)
- ✅ Better error messages and validation
- ✅ Unified support and documentation
- ✅ Future-proof (active development)
- ❌ Doesn't support concurrency > 1

**External package:**
- ✅ Backward compatibility with existing projects
- ✅ Allows concurrency (even though it's unsafe)
- ⚠️ Maintenance mode (no new features)
- ❌ Risk of silent data loss with concurrency
- ❌ Less validation and error context

**Recommendation:** Use built-in support for all new projects and migrate existing projects when feasible.

## Further Reading

- [How to Migrate from External Package](../howtos/migrating-from-commanded-ecto-projections.md)
- [Ecto Projections Architecture](ecto-projections.md)
- [Why Concurrency Is Not Supported](ecto-projections.md#why-concurrency-is-not-supported)
- [Building Read Models with Batch Processing](../howtos/building-read-models-with-ecto.md#use-batch-processing-for-high-throughput)

