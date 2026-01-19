defmodule Commanded.OpenTelemetry.AggregatePopulate do
  @moduledoc false

  alias Commanded.OpenTelemetry.CommandedAttributes
  alias OpenTelemetry.SemConv.Incubating.CodeAttributes
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes
  alias OpenTelemetry.Span

  @tracer_id __MODULE__

  def setup do
    :ok =
      :telemetry.attach_many(
        {__MODULE__, :populate},
        [
          [:commanded, :aggregate, :populate, :start],
          [:commanded, :aggregate, :populate, :stop]
        ],
        &__MODULE__.handle_telemetry_event/4,
        %{}
      )
  end

  def handle_telemetry_event(
        [:commanded, :aggregate, :populate, :start],
        _measurements,
        meta,
        _config
      ) do
    attributes = [
      # OTel Messaging SemConv
      {MessagingAttributes.messaging_system(), "commanded"},
      {MessagingAttributes.messaging_operation_type(), :receive},
      {MessagingAttributes.messaging_operation_name(), "populate"},
      # OTel Code SemConv
      {CodeAttributes.code_function(), "populate"},
      # Commanded-specific
      {CommandedAttributes.commanded_application(), meta.application},
      {CommandedAttributes.commanded_aggregate_uuid(), meta.aggregate_uuid},
      {CommandedAttributes.commanded_aggregate_version(), meta.aggregate_version}
    ]

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "commanded.aggregate.populate",
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
end
