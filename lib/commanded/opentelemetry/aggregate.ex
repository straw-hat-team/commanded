defmodule Commanded.OpenTelemetry.Aggregate do
  @moduledoc false

  alias Commanded.OpenTelemetry.CommandedAttributes
  alias Commanded.OpenTelemetry.Helpers
  alias Commanded.OpenTelemetry.SemConv
  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes
  alias OpenTelemetry.Span

  @tracer_id __MODULE__

  def setup(config \\ []) do
    :ok =
      :telemetry.attach_many(
        {__MODULE__, :execute},
        [
          [:commanded, :aggregate, :execute, :start],
          [:commanded, :aggregate, :execute, :stop],
          [:commanded, :aggregate, :execute, :exception]
        ],
        &__MODULE__.handle_telemetry_event/4,
        config
      )
  end

  def handle_telemetry_event(
        [:commanded, :aggregate, :execute, :start],
        _measurements,
        meta,
        _config
      ) do
    context = meta.execution_context

    case Helpers.extract_propagated_ctx(context.metadata) do
      {_links, :undefined} -> Helpers.clear_ctx()
      {_links, ctx} -> :otel_ctx.attach(ctx)
    end

    handler_module_name = Helpers.module_name(context.handler)

    attributes =
      [
        legacy_messaging_attrs(context, handler_module_name, meta),
        Helpers.maybe_attr(
          SemConv.code_function_name_key(),
          SemConv.code_function_name(context.handler, context.function)
        ),
        {CommandedAttributes.commanded_handler_kind(), "aggregate"},
        {CommandedAttributes.commanded_application(), Helpers.module_name(meta.application)},
        {CommandedAttributes.commanded_aggregate_uuid(), meta.aggregate_uuid},
        {CommandedAttributes.commanded_aggregate_version(), meta.aggregate_version},
        {CommandedAttributes.commanded_command(), Helpers.struct_name(context.command)},
        {CommandedAttributes.commanded_correlation_id(), context.correlation_id},
        {CommandedAttributes.commanded_causation_id(), context.causation_id},
        {CommandedAttributes.commanded_registry_adapter(),
         Helpers.module_name(meta.registry_adapter)}
      ]
      |> List.flatten()
      |> Helpers.compact_attrs()

    # OTel semconv: span name = "{operation.name} {destination.name}"
    span_name = "execute #{handler_module_name}"

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      span_name,
      meta,
      %{
        kind: span_kind(),
        attributes: attributes
      }
    )
  end

  def handle_telemetry_event(
        [:commanded, :aggregate, :execute, :stop],
        measurements,
        meta,
        config
      ) do
    event_name = [:commanded, :aggregate, :execute, :stop]
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    events = Map.get(meta, :events, [])
    Span.set_attribute(ctx, CommandedAttributes.commanded_event_count(), Enum.count(events))

    if error = meta[:error] do
      Span.set_attribute(
        ctx,
        ErrorAttributes.error_type(),
        Helpers.to_error_type(error, @tracer_id)
      )

      Helpers.set_error_status(ctx, error, event_name, measurements, meta, config, @tracer_id)
    end

    wrong_expected_version_count = Map.get(meta, :wrong_expected_version_count, 0)

    if wrong_expected_version_count > 0 do
      Span.add_event(ctx, "commanded.aggregate.wrong_expected_version", [
        {CommandedAttributes.commanded_aggregate_version(), meta.aggregate_version},
        {CommandedAttributes.commanded_aggregate_uuid(), meta.aggregate_uuid},
        {CommandedAttributes.commanded_wrong_expected_version_count(),
         wrong_expected_version_count}
      ])
    end

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  def handle_telemetry_event(
        [:commanded, :aggregate, :execute, :exception],
        _measurements,
        %{kind: kind, reason: reason, stacktrace: stacktrace} = meta,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    # TODO: follow up with OTEL team to add exception.kind SemConv attribute
    Span.set_attribute(ctx, :"erlang.exception.kind", kind)

    # Normalize all errors to Elixir exceptions
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

  defp legacy_messaging_attrs(context, handler_module_name, meta) do
    if SemConv.legacy_messaging?() do
      [
        {MessagingAttributes.messaging_system(), "commanded"},
        {MessagingAttributes.messaging_operation_type(),
         SemConv.legacy_messaging_operation_type(:process)},
        {MessagingAttributes.messaging_operation_name(), "execute"},
        {MessagingAttributes.messaging_destination_name(), handler_module_name},
        {MessagingAttributes.messaging_message_id(), context.causation_id},
        {MessagingAttributes.messaging_message_conversation_id(), context.correlation_id},
        {MessagingAttributes.messaging_consumer_group_name(),
         Helpers.module_name(meta.application)}
      ]
    else
      []
    end
  end

  defp span_kind do
    if SemConv.stable_messaging?(), do: :internal, else: :consumer
  end
end
