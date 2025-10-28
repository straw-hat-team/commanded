defprotocol Commanded.Event.Upcaster do
  @moduledoc """
  Protocol to allow an event to be transformed before being passed to a
  consumer.

  You can use an upcaster to change the shape of an event (e.g. add a new field
  with a default, rename a field) or rename an event.

  Upcaster will run for new events and for historical events.

  Because the upcaster changes any historical event to the latest version,
  consumers (aggregates and event handlers) only need
  to support the latest version.

  ## Example

      alias Commanded.EventStore.EnrichedMetadata

      defimpl Commanded.Event.Upcaster, for: AnEvent do
        def upcast(%AnEvent{} = event, %EnrichedMetadata{} = metadata) do
          %AnEvent{name: name} = event

          %AnEvent{event | first_name: name}
        end
      end

  ## Metadata

  The `upcast/2` function receives the domain event and an `EnrichedMetadata` struct
  associated with that event.

  The `EnrichedMetadata` struct contains the following fields:

    - `application` - the `Commanded.Application` used to read the event.
    - `event_id` - a globally unique UUID to identify the event.
    - `event_number` - a globally unique, monotonically incrementing integer
      used to order the event amongst all events.
    - `stream_id` - the stream identity for the event.
    - `stream_version` - the version of the stream for the event.
    - `causation_id` - an optional UUID identifier used to identify which
      command caused the event.
    - `correlation_id` - an optional UUID identifier used to correlate related
      commands/events.
    - `created_at` - the datetime, in UTC, indicating when the event was
      created.
    - `metadata` - the user-provided metadata as a string-keyed map.

  """

  alias Commanded.EventStore.EnrichedMetadata

  @fallback_to_any true
  @spec upcast(event :: struct(), metadata :: EnrichedMetadata.t()) :: struct()
  def upcast(event, metadata)
end

defimpl Commanded.Event.Upcaster, for: Any do
  @moduledoc """
  The default implementation of the `Commanded.Event.Upcaster`.

  This will return an event unchanged.
  """

  alias Commanded.EventStore.EnrichedMetadata

  def upcast(event, %EnrichedMetadata{}), do: event
end
