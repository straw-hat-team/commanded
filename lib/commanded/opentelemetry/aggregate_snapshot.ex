defmodule Commanded.OpenTelemetry.AggregateSnapshot do
  @moduledoc false

  alias Commanded.OpenTelemetry.CommandedAttributes
  alias Commanded.OpenTelemetry.Helpers
  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.CodeAttributes
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes
  alias OpenTelemetry.Span

  @tracer_id __MODULE__

  def setup do
    :ok =
      :telemetry.attach_many(
        {__MODULE__, :snapshot},
        [
          [:commanded, :aggregate, :snapshot, :start],
          [:commanded, :aggregate, :snapshot, :stop],
          [:commanded, :aggregate, :snapshot, :exception]
        ],
        &__MODULE__.handle_telemetry_event/4,
        %{}
      )
  end

  def handle_telemetry_event(
        [:commanded, :aggregate, :snapshot, :start],
        _measurements,
        meta,
        _config
      ) do
    aggregate_module_name = Helpers.module_name(meta.aggregate_module)

    attributes =
      [
        {MessagingAttributes.messaging_system(), "commanded"},
        {MessagingAttributes.messaging_operation_type(), :publish},
        {MessagingAttributes.messaging_operation_name(), "snapshot"},
        {MessagingAttributes.messaging_destination_name(), aggregate_module_name},
        {CodeAttributes.code_function(), "snapshot"},
        {CodeAttributes.code_namespace(), aggregate_module_name},
        {CommandedAttributes.commanded_application(), meta.application},
        {CommandedAttributes.commanded_aggregate_uuid(), meta.aggregate_uuid},
        {CommandedAttributes.commanded_aggregate_version(), meta.aggregate_version}
      ]
      |> maybe_add_snapshot_every(meta[:snapshot_every])
      |> maybe_add_snapshot_module_version(meta[:snapshot_module_version])

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "snapshot #{aggregate_module_name}",
      meta,
      %{
        kind: :internal,
        attributes: attributes
      }
    )
  end

  def handle_telemetry_event(
        [:commanded, :aggregate, :snapshot, :stop],
        _measurements,
        meta,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    if error = meta[:error] do
      Span.set_attribute(
        ctx,
        ErrorAttributes.error_type(),
        Helpers.to_error_type(error, @tracer_id)
      )

      Span.set_status(ctx, OpenTelemetry.status(:error, Helpers.format_error(error)))
    end

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  def handle_telemetry_event(
        [:commanded, :aggregate, :snapshot, :exception],
        _measurements,
        %{kind: kind, reason: reason, stacktrace: stacktrace} = meta,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    Span.set_attribute(ctx, :"erlang.exception.kind", kind)

    exception = Exception.normalize(kind, reason, stacktrace)

    Span.set_attribute(
      ctx,
      ErrorAttributes.error_type(),
      Helpers.to_error_type(exception, @tracer_id)
    )

    Span.record_exception(ctx, exception, stacktrace)

    Span.set_status(
      ctx,
      OpenTelemetry.status(:error, Exception.format_banner(kind, reason, stacktrace))
    )

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  defp maybe_add_snapshot_every(attrs, nil), do: attrs

  defp maybe_add_snapshot_every(attrs, snapshot_every) when is_integer(snapshot_every) do
    [{CommandedAttributes.commanded_snapshot_every(), snapshot_every} | attrs]
  end

  defp maybe_add_snapshot_every(attrs, _), do: attrs

  defp maybe_add_snapshot_module_version(attrs, nil), do: attrs

  defp maybe_add_snapshot_module_version(attrs, version) when is_integer(version) do
    [{CommandedAttributes.commanded_snapshot_module_version(), version} | attrs]
  end

  defp maybe_add_snapshot_module_version(attrs, _), do: attrs
end
