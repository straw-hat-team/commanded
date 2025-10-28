# Migrating from v1 to v2

## Overview

Commanded v2.0 introduces breaking changes to improve type safety and API clarity. The primary change is that metadata passed to event handlers has been changed from a plain map to the `Commanded.EventStore.EnrichedMetadata` struct.

The issues come when you need to propagate the used-provided metadata, and you need to drop some keys, example:

```elixir
defp drop_internal_metadata(metadata) do
    Map.drop(metadata, [
      :state,
      :application,
      :handler_name,
      :event_id,
      :created_at,
      :correlation_id,
      :causation_id,
      :event_number,
      :stream_id,
      :stream_version
    ])
  end
```

Having a struct helps the compiler and makes such situation simpler without potential unwanted behaviour in the future.

This guide will help you migrate your existing Commanded v1.x applications to v2.0.

### Main Changes in v2.0

#### Metadata Structure

- Metadata is now a `Commanded.EventStore.EnrichedMetadata` struct instead of a plain map
- System metadata fields are separated from user-provided metadata
- Better type safety with compile-time guarantees
- No risk of field name conflicts between system and user metadata

## Before and After Examples

**Before (v1.x):**

```elixir
def handle(%AnEvent{} = event, metadata) do
  %{event_id: event_id, correlation_id: correlation_id} = metadata
  user_value = Map.get(metadata, "user_key")
  # ...
end
```

**After (v2.0):**

```elixir
alias Commanded.EventStore.EnrichedMetadata

def handle(%AnEvent{} = event, %EnrichedMetadata{} = metadata) do
  %EnrichedMetadata{event_id: event_id, correlation_id: correlation_id} = metadata

  # User-provided metadata is now in the metadata field
  user_value = Map.get(metadata.metadata, "user_key")
  # ...
end
```

## Step-by-Step Migration

1. **Update your event handler callbacks:**

   ```elixir
   # Add the alias
   alias Commanded.EventStore.EnrichedMetadata

   # Update the handle/2 function signature
   def handle(event, %EnrichedMetadata{} = metadata) do
     # Access system fields directly
     event_id = metadata.event_id

     # Access user metadata through the metadata field
     user_data = metadata.metadata
   end
   ```

2. **Update pattern matching:**

   ```elixir
   # Before
   def interested?(%Event{}, %{"tenant_id" => tenant_id}) do
     {:start, tenant_id}
   end

   # After
   def interested?(%Event{}, %EnrichedMetadata{metadata: %{"tenant_id" => tenant_id}}) do
     {:start, tenant_id}
   end
   ```

## System Metadata Fields

The following fields are now directly accessible on the `EnrichedMetadata` struct:

- `event_id`
- `event_number`
- `stream_id`
- `stream_version`
- `correlation_id`
- `causation_id`
- `created_at`
- `application` (when available)
- `handler_name` (when available)
- `state` (when available)

User-provided metadata is available in the `metadata` field as a map.
