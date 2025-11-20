# Ecto Projections

Ecto projections allow you to build read models from domain events using Ecto as the database layer. They provide automatic idempotency guarantees, transaction support, and efficient batch processing.

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

### Transaction Semantics

All projection operations happen within a database transaction:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.run(:track_projection_version, fn -> update_watermark() end)
|> Ecto.Multi.insert(:my_data, changeset)  # Your projection logic
|> Repo.transaction()
```

If any step fails, the entire transaction rolls back, including the watermark update. This ensures consistency.

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

