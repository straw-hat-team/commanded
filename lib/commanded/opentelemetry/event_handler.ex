defmodule Commanded.OpenTelemetry.EventHandler do
  @moduledoc false

  alias Commanded.OpenTelemetry.CommandedAttributes
  alias Commanded.OpenTelemetry.Helpers
  alias Commanded.OpenTelemetry.SemConv
  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes
  alias OpenTelemetry.Span

  @tracer_id __MODULE__

  def setup(opts \\ []) do
    span_relationship = Keyword.get(opts, :span_relationship, :link)
    config = %{span_relationship: span_relationship}

    :ok = attach_handle_handlers(config)
    :ok = attach_batch_handlers(config)

    :ok
  end

  defp attach_handle_handlers(config) do
    :telemetry.attach_many(
      {__MODULE__, :handle},
      [
        [:commanded, :event, :handle, :start],
        [:commanded, :event, :handle, :stop],
        [:commanded, :event, :handle, :exception]
      ],
      &__MODULE__.handle_telemetry_event/4,
      config
    )
  end

  defp attach_batch_handlers(config) do
    :telemetry.attach_many(
      {__MODULE__, :batch},
      [
        [:commanded, :event, :batch, :start],
        [:commanded, :event, :batch, :stop],
        [:commanded, :event, :batch, :exception]
      ],
      &__MODULE__.batch_telemetry_event/4,
      config
    )
  end

  def handle_telemetry_event([:commanded, :event, :handle, :start], _measurements, meta, config) do
    recorded_event = meta.recorded_event
    span_relationship = config.span_relationship

    links =
      case span_relationship do
        :link ->
          {links, _ctx} = Helpers.extract_propagated_ctx(recorded_event.metadata)
          Helpers.clear_ctx()
          links

        :child ->
          case Helpers.extract_propagated_ctx(recorded_event.metadata) do
            {_links, :undefined} -> Helpers.clear_ctx()
            {_links, ctx} -> :otel_ctx.attach(ctx)
          end

          []

        :none ->
          Helpers.clear_ctx()
          []
      end

    handler_module_name = Helpers.module_name(meta.handler_module)

    attributes =
      [
        handle_messaging_attrs(
          handler_module_name,
          meta.handler_name,
          Helpers.module_name(meta.application),
          recorded_event
        ),
        {SemConv.code_function_name_key(),
         SemConv.code_function_name(meta.handler_module, :handle)},
        {CommandedAttributes.commanded_handler_kind(), "event_handler"},
        {CommandedAttributes.commanded_application(), Helpers.module_name(meta.application)},
        {CommandedAttributes.commanded_handler_name(), meta.handler_name},
        {CommandedAttributes.commanded_event(), recorded_event.event_type},
        {CommandedAttributes.commanded_event_number(), recorded_event.event_number},
        {CommandedAttributes.commanded_correlation_id(), recorded_event.correlation_id},
        {CommandedAttributes.commanded_causation_id(), recorded_event.causation_id},
        {CommandedAttributes.commanded_stream_id(), recorded_event.stream_id},
        {CommandedAttributes.commanded_stream_version(), recorded_event.stream_version}
      ]
      |> List.flatten()
      |> Helpers.compact_attrs()

    # TODO: Add consistency attribute when available in telemetry metadata
    # consistency: meta.consistency

    # TODO: Add last_seen_event attribute when available in Commanded telemetry
    # "event.last_seen": meta.last_seen_event

    span_opts = %{kind: :consumer, attributes: attributes}
    span_opts = put_links(span_opts, links)

    # OTel semconv: span name = "{operation.name} {destination.name}"
    span_name = "handle #{handler_module_name}"

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      span_name,
      meta,
      span_opts
    )
  end

  def handle_telemetry_event([:commanded, :event, :handle, :stop], measurements, meta, _config) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    put_handler_processing_latency(ctx, measurements)

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
        [:commanded, :event, :handle, :exception],
        _measurements,
        %{kind: kind, reason: reason, stacktrace: stacktrace} = meta,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    # TODO: follow up with OTEL team to add exception.kind SemConv attribute
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

  def batch_telemetry_event([:commanded, :event, :batch, :start], _measurements, meta, _config) do
    # Note: Batch telemetry metadata does not include individual recorded_events,
    # only first_event_id, last_event_id, and event_count. Therefore, we cannot
    # create span links to individual command dispatch traces for batch events.
    # See: lib/commanded/event/handler.ex - batch_telemetry_metadata/3
    #
    # Since batch metadata doesn't include traceparent, we always clear context
    # to start fresh traces. This ensures batch spans don't accidentally inherit
    # stale context from the process dictionary (from other OTel instrumentation).
    Helpers.clear_ctx()

    handler_module_name = Helpers.module_name(meta.handler_module)

    attributes =
      [
        batch_messaging_attrs(
          handler_module_name,
          meta.handler_name,
          Helpers.module_name(meta.application),
          meta.event_count
        ),
        {SemConv.code_function_name_key(),
         SemConv.code_function_name(meta.handler_module, :handle_batch)},
        {CommandedAttributes.commanded_handler_kind(), "event_handler"},
        {CommandedAttributes.commanded_application(), Helpers.module_name(meta.application)},
        {CommandedAttributes.commanded_handler_name(), meta.handler_name},
        {CommandedAttributes.commanded_event_count(), meta.event_count},
        {CommandedAttributes.commanded_batch_first_event_id(), meta.first_event_id},
        {CommandedAttributes.commanded_batch_last_event_id(), meta.last_event_id}
      ]
      |> List.flatten()
      |> Helpers.compact_attrs()

    span_opts = %{kind: :consumer, attributes: attributes}

    # OTel semconv: span name = "{operation.name} {destination.name}"
    span_name = "batch #{handler_module_name}"

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      span_name,
      meta,
      span_opts
    )
  end

  def batch_telemetry_event([:commanded, :event, :batch, :stop], measurements, meta, _config) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    put_handler_processing_latency(ctx, measurements)

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

  def batch_telemetry_event(
        [:commanded, :event, :batch, :exception],
        _measurements,
        %{kind: kind, reason: reason, stacktrace: stacktrace} = meta,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    # TODO: follow up with OTEL team to add exception.kind SemConv attribute
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

  defp put_handler_processing_latency(ctx, %{processing_latency_ms: latency})
       when is_integer(latency) do
    Span.set_attribute(ctx, CommandedAttributes.commanded_handler_processing_latency(), latency)
  end

  defp put_handler_processing_latency(_ctx, _measurements), do: :ok

  defp put_links(span_opts, []), do: span_opts
  defp put_links(span_opts, links), do: Map.put(span_opts, :links, links)

  defp handle_messaging_attrs(handler_module_name, handler_name, application_name, recorded_event) do
    operation_type =
      if SemConv.stable_messaging?() do
        SemConv.stable_messaging_operation_type(:process)
      else
        SemConv.legacy_messaging_operation_type(:receive)
      end

    [
      {MessagingAttributes.messaging_system(), "commanded"},
      {MessagingAttributes.messaging_operation_type(), operation_type},
      {MessagingAttributes.messaging_operation_name(), "handle"},
      if(SemConv.legacy_messaging?(),
        do:
          Helpers.maybe_attr(
            MessagingAttributes.messaging_destination_name(),
            handler_module_name
          )
      ),
      {MessagingAttributes.messaging_destination_subscription_name(), handler_name},
      {MessagingAttributes.messaging_message_id(), recorded_event.event_id},
      {MessagingAttributes.messaging_message_conversation_id(), recorded_event.correlation_id},
      {MessagingAttributes.messaging_consumer_group_name(), application_name}
    ]
    |> Helpers.compact_attrs()
  end

  defp batch_messaging_attrs(handler_module_name, handler_name, application_name, event_count) do
    operation_type =
      if SemConv.stable_messaging?() do
        SemConv.stable_messaging_operation_type(:process)
      else
        SemConv.legacy_messaging_operation_type(:receive)
      end

    [
      {MessagingAttributes.messaging_system(), "commanded"},
      {MessagingAttributes.messaging_operation_type(), operation_type},
      {MessagingAttributes.messaging_operation_name(), "batch"},
      if(SemConv.legacy_messaging?(),
        do:
          Helpers.maybe_attr(
            MessagingAttributes.messaging_destination_name(),
            handler_module_name
          )
      ),
      {MessagingAttributes.messaging_destination_subscription_name(), handler_name},
      {MessagingAttributes.messaging_consumer_group_name(), application_name},
      {MessagingAttributes.messaging_batch_message_count(), event_count}
    ]
    |> Helpers.compact_attrs()
  end
end
