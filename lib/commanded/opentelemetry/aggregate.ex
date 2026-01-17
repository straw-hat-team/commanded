defmodule Commanded.OpenTelemetry.Aggregate do
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
        {__MODULE__, :execute},
        [
          [:commanded, :aggregate, :execute, :start],
          [:commanded, :aggregate, :execute, :stop],
          [:commanded, :aggregate, :execute, :exception]
        ],
        &__MODULE__.handle_telemetry_event/4,
        %{}
      )
  end

  def handle_telemetry_event(
        [:commanded, :aggregate, :execute, :start],
        _measurements,
        meta,
        _config
      ) do
    context = meta.execution_context

    # Propagate trace context from command metadata (aggregates run in separate processes)
    # Uses W3C traceparent/tracestate headers injected by TraceContextPropagator middleware
    Helpers.attach_ctx(context.metadata)

    handler_module_name = Helpers.module_name(context.handler)

    attributes = [
      # OTel Messaging SemConv
      {MessagingAttributes.messaging_system(), "commanded"},
      {MessagingAttributes.messaging_operation_type(), :process},
      {MessagingAttributes.messaging_operation_name(), "execute"},
      {MessagingAttributes.messaging_destination_name(), handler_module_name},
      {MessagingAttributes.messaging_message_id(), context.causation_id},
      {MessagingAttributes.messaging_message_conversation_id(), context.correlation_id},
      {MessagingAttributes.messaging_consumer_group_name(), meta.application},
      # OTel Code SemConv
      {CodeAttributes.code_function(), to_string(context.function)},
      {CodeAttributes.code_namespace(), handler_module_name},
      # Commanded-specific
      {CommandedAttributes.commanded_handler_kind(), "aggregate"},
      {CommandedAttributes.commanded_application(), meta.application},
      {CommandedAttributes.commanded_aggregate_uuid(), meta.aggregate_uuid},
      {CommandedAttributes.commanded_aggregate_version(), meta.aggregate_version},
      {CommandedAttributes.commanded_command(), Helpers.struct_name(context.command)},
      {CommandedAttributes.commanded_correlation_id(), context.correlation_id},
      {CommandedAttributes.commanded_causation_id(), context.causation_id}
    ]

    # OTel semconv: span name = "{operation.name} {destination.name}"
    span_name = "execute #{handler_module_name}"

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      span_name,
      meta,
      %{
        kind: :consumer,
        attributes: attributes
      }
    )
  end

  def handle_telemetry_event(
        [:commanded, :aggregate, :execute, :stop],
        _measurements,
        meta,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    events = Map.get(meta, :events, [])
    Span.set_attribute(ctx, CommandedAttributes.commanded_event_count(), Enum.count(events))

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
end
