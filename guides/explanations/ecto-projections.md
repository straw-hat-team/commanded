# Ecto Projections

This document explains the architecture, design decisions, and concepts behind Ecto projections in Commanded. Understanding these concepts will help you build robust read models.

Ecto projections allow you to build read models from domain events using Ecto as the database layer. They provide automatic idempotency guarantees, transaction support, and efficient batch processing.

**See also:** [Building Read Models How-To](../howtos/building-read-models-with-ecto.md) for practical examples

## What are Ecto Projections?

An Ecto projection is a specialized event handler that projects domain events into a relational database using Ecto. Unlike regular event handlers, Ecto projections:

- **Guarantee idempotency** - Each event is projected exactly once using watermark-based tracking
- **Use database transactions** - All operations execute atomically via `Ecto.Multi`
- **Support batch processing** - Process multiple events in a single transaction for high throughput

## Architecture

### Event Handler Foundation

Ecto projections are built on top of `Commanded.Event.Handler`, which means they:

- Run as supervised GenServer processes
- Subscribe to the event store
- Receive events in order (within a single handler instance)
- Support the same lifecycle callbacks (init, error handling, etc.)

### Idempotency Mechanism

Ecto projections use a **watermark-based idempotency** strategy:

1. A `projection_versions` table tracks the last seen event number for each projector
2. Before processing an event, the projector checks: `event_number > last_seen_event_number`
3. If true, the event is processed and the watermark is updated
4. If false, the event is skipped (already processed)

This approach is:
- **Simple** - Single integer comparison
- **Fast** - One row per projector (not one row per event)
- **Correct** - Works perfectly for sequential processing

### Projection Watermark vs Event Store Checkpoint

> #### Common Question {: .info}
>
> "Why is my `projection_versions.last_seen_event_number` (1000) different from my event store subscription checkpoint (1500)? Is this a bug?"

**No, this is expected behavior.** These two numbers track different things:

**Projection Watermark (`projection_versions` table):**
- Updated ONLY when an event is **actually projected**
- Shows the last event that was **processed by your projection logic**
- Stored in your application database

**Event Store Subscription Checkpoint:**
- Updated after EVERY event is **delivered to the handler**
- Shows the last event that was **seen by the subscription**
- Stored by the event store (EventStore or other)

#### Why They Differ

The projection watermark and subscription checkpoint will differ when:

1. **Event is not handled by projector:**
```elixir
# Your projector only handles AccountOpened events
project %AccountOpened{}, _metadata, fn multi ->
  # Watermark updates here (when transaction commits)
  Ecto.Multi.insert(multi, :account, ...)
end

# When AccountClosed event arrives:
# - Subscription checkpoint moves forward (event was delivered)
# - Projection watermark stays the same (event not projected)
```

2. **Multiple event types, selective projection:**
```elixir
# Events 1-10 arrive, but only events 2, 5, 8 match your projection
# Subscription checkpoint: 10
# Projection watermark: 8 (last projected event)
```

3. **Idempotency check fails (event already seen):**
```elixir
# Event arrives but watermark shows it was already processed
# - Subscription checkpoint moves forward
# - Projection watermark stays the same (no work done)
```

#### Monitoring Implications

When monitoring projections, understand what each metric means:

**Projection Watermark** tells you:
- ✅ Last event your business logic processed
- ✅ Progress of your actual read model
- ✅ What data is in your projection tables

**Subscription Checkpoint** tells you:
- ✅ Last event delivered by event store
- ✅ Connection health to event store
- ✅ If subscription is keeping up

**Both are correct.** The gap between them is normal and expected when:
- Your projector is selective (doesn't project all events)
- Events are being skipped due to idempotency
- Your projector subscribes to specific streams only

#### What to Alert On

**Good metrics:**
- Projection watermark not advancing (projector may be stuck)
- Subscription checkpoint not advancing (connection issue)
- Gap between watermark and checkpoint growing significantly (performance issue or projector not handling events)

**Don't alert on:**
- Static difference between watermark and checkpoint (normal when selective)
- Small gaps (expected with idempotency checks)

### Transaction Semantics

All projection operations happen within a database transaction:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.run(:track_projection_version, fn -> update_watermark() end)
|> Ecto.Multi.insert(:my_data, changeset)  # Your projection logic
|> Repo.transaction()
```

The watermark update and your projection logic are atomic - both succeed or both fail. If any step fails, the entire transaction rolls back, including the watermark update. This ensures consistency and guarantees exactly-once processing semantics.

### After-Update Callbacks

The `after_update/3` and `after_update_batch/2` callbacks execute **AFTER** the transaction commits:

- **Side effects only** - Use for notifications, pub/sub, external API calls
- **Cannot rollback** - Database changes are already committed
- **Errors propagate** - But the data is already saved

This design prevents long-running side effects from blocking the transaction.

## Batch Processing

Batch processing allows high throughput by processing multiple events in a single database transaction:

```elixir
use Commanded.Projections.Ecto,
  batch_size: 50  # Process 50 events per transaction
```

**How it works:**

1. Collect up to `batch_size` events from subscription
2. Start transaction
3. Lock projection version row (`FOR UPDATE`)
4. Filter events: keep only those with `event_number > watermark`
5. Update watermark to highest event number in batch
6. Execute user's projection logic for all unseen events
7. Commit transaction

**Benefits:**

- Reduced transaction overhead (1 transaction for N events instead of N transactions)
- Single fsync for the entire batch
- Better throughput for high-volume event streams

**Trade-offs:**

- Higher latency (wait for batch to fill or timeout)
- Mutually exclusive with concurrency
- Requires static schema prefix (no per-event dynamic schemas)

## Why Concurrency Is Not Supported

> #### Concurrency Not Supported {: .error}
>
> Ecto projections do not support `concurrency > 1` due to the watermark-based idempotency mechanism.

**The Problem:**

With concurrent workers processing events in parallel:

```
Time    Worker 1        Worker 2        Watermark
----    --------        --------        ---------
T1      Event #3        Event #5            0
T2      Updates: 3      Updates: 5          5  (Worker 2 commits first)
T3      Event #4 arrives                    5
T4      SKIPPED (4 < 5) ❌                  5
```

Event #4 is permanently lost because the watermark already moved past it.

**Why Regular Event Handlers Can Use Concurrency:**

Regular event handlers don't use watermark idempotency - they rely on the event store subscription's checkpoint. With `partition_by/2`, they guarantee per-partition ordering while allowing cross-partition concurrency.

**The Solution for Ecto Projections:**

Use `:batch_size` instead of `:concurrency`:
- Maintains event ordering
- Provides high throughput
- Safe with watermark idempotency

## Schema Prefixes

Schema prefixes allow multi-tenant projections where each tenant's data lives in a separate PostgreSQL schema:

```elixir
def schema_prefix(%Event{tenant: tenant}, _metadata), do: tenant
```

The `projection_versions` table will be read/written in the tenant's schema, ensuring complete isolation.

> #### Batch Processing Limitation {: .warning}
>
> Batch projectors only support **static** schema prefixes (strings), not dynamic functions.
> This is because the entire batch must use the same schema - we can't mix events from
> different tenants in a single transaction.

## Consistency Guarantees

Ecto projections support two consistency levels that control when command dispatch returns relative to projection updates.

### Eventual Consistency (Default)

With eventual consistency, command dispatch returns immediately after events are persisted to the event store, without waiting for projections to update:

```elixir
defmodule MyApp.AccountProjector do
  use Commanded.Projections.Ecto,
    application: MyApp,
    repo: MyApp.Repo,
    name: "account_projector",
    consistency: :eventual  # Or omit (this is the default)

  project %AccountOpened{}, _metadata, fn multi ->
    Ecto.Multi.insert(multi, :account, %Account{...})
  end
end
```

**Characteristics:**
- ✅ **Fast command dispatch** - Returns immediately after event persistence
- ✅ **Best throughput** - No blocking on projections
- ❌ **Read-your-own-writes not guaranteed** - Projection might not be updated yet when command returns

**Use when:**
- Commands and queries happen in different requests
- Slight delay in read model updates is acceptable
- Maximizing command throughput is important

### Strong Consistency

With strong consistency, command dispatch waits for all `:strong` projections to complete before returning:

```elixir
defmodule MyApp.AccountProjector do
  use Commanded.Projections.Ecto,
    application: MyApp,
    repo: MyApp.Repo,
    name: "account_projector",
    consistency: :strong

  project %AccountOpened{account_id: id, name: name}, _metadata, fn multi ->
    Ecto.Multi.insert(multi, :account, %Account{id: id, name: name})
  end
end
```

**Characteristics:**
- ✅ **Read-your-own-writes guaranteed** - Projection is updated before command returns
- ✅ **Immediate consistency** - Can query read model immediately after command
- ❌ **Slower command dispatch** - Waits for projection to complete
- ❌ **Not a transaction** - Events are persisted even if projection fails

**Use when:**
- You need to query the read model immediately after the command
- User needs to see their changes right away
- Implementing CQRS with synchronous reads

### How Consistency Affects Command Dispatch

The consistency setting controls when command dispatch returns relative to projection updates:

**With `:eventual` (default):**
- Command dispatch returns immediately after events are persisted
- Projections process events asynchronously
- Query immediately after dispatch may not show updates

**With `:strong`:**
- Command dispatch waits for all `:strong` projections to complete
- Projections are guaranteed to be updated when dispatch returns
- Query immediately after dispatch will show updates

> For usage examples, see module documentation for `Commanded.Projections.Ecto`

### Important Notes

**Consistency is Not a Transaction:**

Strong consistency guarantees the projection handler has processed the events, but it does NOT mean:
- ❌ Projection and command are in same database transaction
- ❌ Projection success affects event persistence
- ❌ Projection failure rolls back the events

Even with `:strong` consistency:
- Events are persisted first
- Then projections process them
- If projection fails, events remain persisted
- The projection will retry on its own

**What Strong Consistency Guarantees:**

```elixir
# With :strong consistency
{:ok, _} = MyApp.dispatch(command, consistency: :strong)

# At this point, you are guaranteed:
# ✅ Events are persisted in event store
# ✅ All :strong projections have processed the events
# ✅ All :strong projection transactions have committed
# ✅ Read model is up-to-date with these events

# You are NOT guaranteed:
# ❌ No errors occurred during projection (it may have retried)
# ❌ Other :eventual projections have processed the events
```

**Error Handling:**

If a `:strong` projection fails:
- The projection will retry according to its `error/3` callback
- Command dispatch will wait for successful projection
- If projection continues to fail, command dispatch will timeout
- But the events are already persisted

### Combining with Batch Processing

Consistency works with batch processing:

```elixir
defmodule MyApp.FastAccountProjector do
  use Commanded.Projections.Ecto,
    application: MyApp,
    repo: MyApp.Repo,
    name: "fast_account_projector",
    batch_size: 50,        # ✅ Batching for performance
    consistency: :strong    # ✅ Strong consistency for reads

  project_batch fn events, multi ->
    # Process batch
  end
end

# Command dispatch waits for entire batch to be processed
MyApp.dispatch(command, consistency: :strong)
```

**Trade-off:** Strong consistency with batching means command dispatch waits for the batch to fill and process. This can add latency.

### When to Use Each

**Use `:eventual` (default) when:**
- Commands and queries are in separate HTTP requests
- Slight delay (milliseconds to seconds) is acceptable
- You want maximum command throughput
- Processing background/async workflows

**Use `:strong` when:**
- User expects to see their changes immediately
- You query the read model right after the command
- Implementing synchronous APIs
- Testing (easier to write tests when reads are immediate)

**Example Scenario:**

In a user registration flow, you might use eventual consistency for sending welcome emails (can be delayed) but strong consistency for the user profile projection (must be immediately queryable for the next page load).

> For complete code examples, see [Building Read Models How-To](../howtos/building-read-models-with-ecto.md)

## Design Decisions

### Why Watermark Instead of Per-Event Tracking?

**Watermark approach:**
- Storage: 1 row per projector
- Lookup: Single integer comparison
- Write: 1 update per event/batch

**Per-event tracking:**
- Storage: 1 row per projector per event (can be millions)
- Lookup: Check if event_number exists in table
- Write: 1 insert per event

The watermark approach is simpler and more efficient for the 99% case (sequential processing). Per-event tracking would be needed only if we wanted to support concurrent processing in the future.

### Why Batch Processing Over Concurrency?

Batch processing provides:
- Ordering guarantees (required for correctness)
- High throughput (fewer transactions)
- Simpler code (single watermark update)

Concurrency would require:
- Per-partition watermarks
- Complex coordination logic
- Higher storage overhead

For read models, throughput via batching is sufficient. If you need parallel processing, consider multiple projectors subscribing to different streams.

