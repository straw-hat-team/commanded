defmodule Commanded.OpenTelemetry.CommandedAttributes do
  @moduledoc """
  OpenTelemetry span attribute names for Commanded.

  This module provides constant attribute names following OpenTelemetry semantic
  conventions for Commanded-specific span attributes.

  ## Naming Conventions

  All attributes `MUST` follow the OpenTelemetry Semantic Conventions naming guidelines:

  - Prefix with `commanded.` to avoid conflicts with standard OTel attributes.
  - Use `snake_case` for attribute names.
  - Use `_count` suffix for counter attributes (e.g., `commanded.event.count`).
  - Use dot notation for namespacing (e.g., `commanded.stream.version`).
  - To extend a SemConv namespace, use `commanded.<namespace>.*` (e.g., `commanded.messaging.*`).

  ## Example

      iex> Commanded.OpenTelemetry.CommandedAttributes.commanded_event()
      :"commanded.event"

  """

  @doc """
  Type of handler (command_handler, aggregate, event_handler).
  """
  @spec commanded_handler_kind() :: :"commanded.handler.kind"
  def commanded_handler_kind, do: :"commanded.handler.kind"

  @doc """
  The Commanded application module name.
  """
  @spec commanded_application() :: :"commanded.application"
  def commanded_application, do: :"commanded.application"

  @doc """
  The aggregate's unique identifier.
  """
  @spec commanded_aggregate_uuid() :: :"commanded.aggregate.uuid"
  def commanded_aggregate_uuid, do: :"commanded.aggregate.uuid"

  @doc """
  The aggregate's current version number.
  """
  @spec commanded_aggregate_version() :: :"commanded.aggregate.version"
  def commanded_aggregate_version, do: :"commanded.aggregate.version"

  @doc """
  The command struct name being dispatched.
  """
  @spec commanded_command() :: :"commanded.command"
  def commanded_command, do: :"commanded.command"

  @doc """
  The correlation ID for tracing related operations.
  """
  @spec commanded_correlation_id() :: :"commanded.correlation_id"
  def commanded_correlation_id, do: :"commanded.correlation_id"

  @doc """
  The causation ID linking cause and effect.
  """
  @spec commanded_causation_id() :: :"commanded.causation_id"
  def commanded_causation_id, do: :"commanded.causation_id"

  @doc """
  The event struct name being processed.
  """
  @spec commanded_event() :: :"commanded.event"
  def commanded_event, do: :"commanded.event"

  @doc """
  The event's global sequence number.
  """
  @spec commanded_event_number() :: :"commanded.event.number"
  def commanded_event_number, do: :"commanded.event.number"

  @doc """
  Number of events in a batch or produced by a command.
  """
  @spec commanded_event_count() :: :"commanded.event.count"
  def commanded_event_count, do: :"commanded.event.count"

  @doc """
  The event handler's registered name.
  """
  @spec commanded_handler_name() :: :"commanded.handler.name"
  def commanded_handler_name, do: :"commanded.handler.name"

  @doc """
  The stream identifier (e.g., aggregate type + uuid).
  """
  @spec commanded_stream_id() :: :"commanded.stream.id"
  def commanded_stream_id, do: :"commanded.stream.id"

  @doc """
  The stream's unique identifier.
  """
  @spec commanded_stream_uuid() :: :"commanded.stream.uuid"
  def commanded_stream_uuid, do: :"commanded.stream.uuid"

  @doc """
  The event's position within its stream.
  """
  @spec commanded_stream_version() :: :"commanded.stream.version"
  def commanded_stream_version, do: :"commanded.stream.version"

  @doc """
  Expected version for optimistic concurrency control.
  """
  @spec commanded_expected_version() :: :"commanded.expected_version"
  def commanded_expected_version, do: :"commanded.expected_version"

  @doc """
  Source UUID for projections.
  """
  @spec commanded_source_uuid() :: :"commanded.source.uuid"
  def commanded_source_uuid, do: :"commanded.source.uuid"

  @doc """
  Starting position for subscriptions (:origin, :current, or event number).
  """
  @spec commanded_start_from() :: :"commanded.start_from"
  def commanded_start_from, do: :"commanded.start_from"

  @doc """
  The subscription name for event handlers.
  """
  @spec commanded_subscription_name() :: :"commanded.subscription.name"
  def commanded_subscription_name, do: :"commanded.subscription.name"

  @doc """
  The first event ID in a batch.
  """
  @spec commanded_batch_first_event_id() :: :"commanded.batch.first_event_id"
  def commanded_batch_first_event_id, do: :"commanded.batch.first_event_id"

  @doc """
  The last event ID in a batch.
  """
  @spec commanded_batch_last_event_id() :: :"commanded.batch.last_event_id"
  def commanded_batch_last_event_id, do: :"commanded.batch.last_event_id"

  @doc """
  Whether a snapshot was used during aggregate populate.
  """
  @spec commanded_snapshot_used() :: :"commanded.snapshot.used"
  def commanded_snapshot_used, do: :"commanded.snapshot.used"

  @doc """
  The version the snapshot was taken at.
  """
  @spec commanded_snapshot_source_version() :: :"commanded.snapshot.source_version"
  def commanded_snapshot_source_version, do: :"commanded.snapshot.source_version"

  @doc """
  The configured snapshot_every value (events between snapshots).
  """
  @spec commanded_snapshot_every() :: :"commanded.snapshot.every"
  def commanded_snapshot_every, do: :"commanded.snapshot.every"

  @doc """
  The configured snapshot module version.
  """
  @spec commanded_snapshot_module_version() :: :"commanded.snapshot.module_version"
  def commanded_snapshot_module_version, do: :"commanded.snapshot.module_version"

  @doc """
  Number of wrong_expected_version conflicts during a single command execution.
  """
  @spec commanded_wrong_expected_version_count() :: :"commanded.wrong_expected_version.count"
  def commanded_wrong_expected_version_count, do: :"commanded.wrong_expected_version.count"
end
