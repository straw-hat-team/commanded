defmodule Commanded.EventStore.EnrichedMetadata do
  @moduledoc """
  Enriched metadata struct containing system fields and user-provided metadata.

  ## Fields

    - `event_id` - a globally unique UUID to identify the event.
    - `event_number` - a globally unique, monotonically incrementing integer.
    - `stream_id` - the stream identity for the event.
    - `stream_version` - the version of the stream for the event.
    - `correlation_id` - an optional UUID identifier used to correlate related commands/events.
    - `causation_id` - an optional UUID identifier used to identify which command caused the event.
    - `created_at` - the datetime, in UTC, indicating when the event was created.
    - `application` - the Commanded Application module (optional).
    - `handler_name` - the name of the event handler (optional).
    - `state` - optional event handler state (optional).
    - `metadata` - user-provided metadata as a string-keyed map. Always defaults to an empty map if not provided.
  """

  @type t :: %__MODULE__{
          event_id: String.t(),
          event_number: non_neg_integer(),
          stream_id: String.t(),
          stream_version: non_neg_integer(),
          correlation_id: String.t() | nil,
          causation_id: String.t() | nil,
          created_at: DateTime.t(),
          application: module() | nil,
          handler_name: String.t() | nil,
          state: any() | nil,
          metadata: map()
        }

  @enforce_keys [
    :event_id,
    :event_number,
    :stream_id,
    :stream_version,
    :created_at
  ]

  defstruct [
    :event_id,
    :event_number,
    :stream_id,
    :stream_version,
    :correlation_id,
    :causation_id,
    :created_at,
    :application,
    :handler_name,
    :state,
    metadata: %{}
  ]
end
