defmodule Commanded.OpenTelemetry.AggregatePopulate do
  @moduledoc false

  alias Commanded.OpenTelemetry.CommandedAttributes
  alias Commanded.OpenTelemetry.Helpers
  alias Commanded.OpenTelemetry.SemConv
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes
  alias OpenTelemetry.Span

  @tracer_id __MODULE__

  def setup do
    :ok =
      :telemetry.attach_many(
        {__MODULE__, :load_populate},
        [
          [:commanded, :aggregate, :load, :start],
          [:commanded, :aggregate, :load, :stop],
          [:commanded, :aggregate, :populate, :start],
          [:commanded, :aggregate, :populate, :stop]
        ],
        &__MODULE__.handle_telemetry_event/4,
        %{}
      )
  end

  def handle_telemetry_event(
        [:commanded, :aggregate, :load, :start],
        _measurements,
        meta,
        _config
      ) do
    case Helpers.extract_propagated_ctx(meta[:metadata]) do
      {_links, :undefined} -> :ok
      {_links, ctx} -> :otel_ctx.attach(ctx)
    end

    aggregate_module_name = Helpers.module_name(meta.aggregate_module)

    attributes =
      [
        legacy_messaging_attrs("load", aggregate_module_name),
        {SemConv.code_function_name_key(),
         SemConv.code_function_name(
           Commanded.Aggregates.AggregateStateBuilder,
           :rebuild_from_events
         )},
        {CommandedAttributes.commanded_application(), Helpers.module_name(meta.application)},
        {CommandedAttributes.commanded_aggregate_uuid(), meta.aggregate_uuid},
        {CommandedAttributes.commanded_aggregate_version(), meta.aggregate_version}
      ]
      |> List.flatten()
      |> Helpers.compact_attrs()

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "load #{aggregate_module_name}",
      meta,
      %{
        kind: :internal,
        attributes: attributes
      }
    )
  end

  def handle_telemetry_event(
        [:commanded, :aggregate, :load, :stop],
        measurements,
        meta,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    event_count = Map.get(measurements, :count, 0)
    Span.set_attribute(ctx, CommandedAttributes.commanded_event_count(), event_count)

    Span.set_attribute(
      ctx,
      CommandedAttributes.commanded_aggregate_version(),
      meta.aggregate_version
    )

    Span.set_attribute(
      ctx,
      CommandedAttributes.commanded_snapshot_used(),
      meta[:snapshot_used] || false
    )

    if snapshot_source_version = meta[:snapshot_source_version] do
      Span.set_attribute(
        ctx,
        CommandedAttributes.commanded_snapshot_source_version(),
        snapshot_source_version
      )
    end

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  def handle_telemetry_event(
        [:commanded, :aggregate, :populate, :start],
        _measurements,
        meta,
        _config
      ) do
    aggregate_module_name = Helpers.module_name(meta.aggregate_module)

    attributes =
      [
        legacy_messaging_attrs("populate", aggregate_module_name),
        {SemConv.code_function_name_key(),
         SemConv.code_function_name(
           Commanded.Aggregates.AggregateStateBuilder,
           :rebuild_from_event_stream
         )},
        {CommandedAttributes.commanded_application(), Helpers.module_name(meta.application)},
        {CommandedAttributes.commanded_aggregate_uuid(), meta.aggregate_uuid},
        {CommandedAttributes.commanded_aggregate_version(), meta.aggregate_version}
      ]
      |> List.flatten()
      |> Helpers.compact_attrs()

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "populate #{aggregate_module_name}",
      meta,
      %{
        kind: :internal,
        attributes: attributes
      }
    )
  end

  def handle_telemetry_event(
        [:commanded, :aggregate, :populate, :stop],
        measurements,
        meta,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    event_count = Map.get(measurements, :count, 0)
    Span.set_attribute(ctx, CommandedAttributes.commanded_event_count(), event_count)

    Span.set_attribute(
      ctx,
      CommandedAttributes.commanded_aggregate_version(),
      meta.aggregate_version
    )

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  defp legacy_messaging_attrs(operation_name, aggregate_module_name) do
    if SemConv.legacy_messaging?() do
      [
        {MessagingAttributes.messaging_system(), "commanded"},
        {MessagingAttributes.messaging_operation_type(),
         SemConv.legacy_messaging_operation_type(:receive)},
        {MessagingAttributes.messaging_operation_name(), operation_name},
        {MessagingAttributes.messaging_destination_name(), aggregate_module_name}
      ]
    else
      []
    end
  end
end
