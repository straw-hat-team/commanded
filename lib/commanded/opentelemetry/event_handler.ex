defmodule Commanded.OpenTelemetry.EventHandler do
  @moduledoc false

  alias Commanded.OpenTelemetry.CommandedAttributes
  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.CodeAttributes
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

    # Clear any stale context and set up links based on span_relationship mode.
    # All modes must explicitly handle context to avoid inheriting unintended parents
    # from pre-existing OTel context in the process dictionary.
    links =
      case span_relationship do
        :link ->
          link_ctx = extract_span_context_for_link(recorded_event.metadata)
          attach_ctx(nil)
          if link_ctx, do: [OpenTelemetry.link(link_ctx)], else: []

        :child ->
          attach_ctx(recorded_event.metadata)
          []

        :none ->
          attach_ctx(nil)
          []
      end

    handler_module_name = module_name(meta.handler_module)

    attributes = [
      # OTel Messaging SemConv
      {MessagingAttributes.messaging_system(), "commanded"},
      {MessagingAttributes.messaging_operation_type(), :receive},
      {MessagingAttributes.messaging_operation_name(), "handle"},
      {MessagingAttributes.messaging_destination_name(), handler_module_name},
      {MessagingAttributes.messaging_destination_subscription_name(), meta.handler_name},
      {MessagingAttributes.messaging_message_id(), recorded_event.event_id},
      {MessagingAttributes.messaging_message_conversation_id(), recorded_event.correlation_id},
      {MessagingAttributes.messaging_consumer_group_name(), meta.application},
      # OTel Code SemConv
      {CodeAttributes.code_function(), "handle"},
      {CodeAttributes.code_namespace(), handler_module_name},
      # Commanded-specific
      {CommandedAttributes.commanded_handler_kind(), "event_handler"},
      {CommandedAttributes.commanded_application(), meta.application},
      {CommandedAttributes.commanded_handler_name(), meta.handler_name},
      {CommandedAttributes.commanded_event(), recorded_event.event_type},
      {CommandedAttributes.commanded_event_number(), recorded_event.event_number},
      {CommandedAttributes.commanded_correlation_id(), recorded_event.correlation_id},
      {CommandedAttributes.commanded_causation_id(), recorded_event.causation_id},
      {CommandedAttributes.commanded_stream_id(), recorded_event.stream_id},
      {CommandedAttributes.commanded_stream_version(), recorded_event.stream_version}
    ]

    # TODO: Add consistency attribute when available in telemetry metadata
    # consistency: meta.consistency

    # TODO: Add last_seen_event attribute when available in Commanded telemetry
    # "event.last_seen": meta.last_seen_event

    span_opts = %{kind: :consumer, attributes: attributes}
    span_opts = put_links(span_opts, links)

    span_name = "#{meta.handler_name} receive"

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      span_name,
      meta,
      span_opts
    )
  end

  def handle_telemetry_event([:commanded, :event, :handle, :stop], _measurements, meta, _config) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    if error = meta[:error] do
      Span.set_attribute(ctx, ErrorAttributes.error_type(), error_type(error))
      Span.set_status(ctx, OpenTelemetry.status(:error, format_error(error)))
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
    Span.set_attribute(ctx, ErrorAttributes.error_type(), error_type(exception))
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
    attach_ctx(nil)

    handler_module_name = module_name(meta.handler_module)

    attributes = [
      # OTel Messaging SemConv
      {MessagingAttributes.messaging_system(), "commanded"},
      {MessagingAttributes.messaging_operation_type(), :receive},
      {MessagingAttributes.messaging_operation_name(), "batch"},
      {MessagingAttributes.messaging_destination_name(), handler_module_name},
      {MessagingAttributes.messaging_destination_subscription_name(), meta.handler_name},
      {MessagingAttributes.messaging_consumer_group_name(), meta.application},
      {MessagingAttributes.messaging_batch_message_count(), meta.event_count},
      # OTel Code SemConv
      {CodeAttributes.code_function(), "handle_batch"},
      {CodeAttributes.code_namespace(), handler_module_name},
      # Commanded-specific
      {CommandedAttributes.commanded_handler_kind(), "event_handler"},
      {CommandedAttributes.commanded_application(), meta.application},
      {CommandedAttributes.commanded_handler_name(), meta.handler_name},
      {CommandedAttributes.commanded_event_count(), meta.event_count},
      {CommandedAttributes.commanded_batch_first_event_id(), meta.first_event_id},
      {CommandedAttributes.commanded_batch_last_event_id(), meta.last_event_id}
    ]

    span_opts = %{kind: :consumer, attributes: attributes}

    span_name = "#{meta.handler_name} batch"

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      span_name,
      meta,
      span_opts
    )
  end

  def batch_telemetry_event([:commanded, :event, :batch, :stop], _measurements, meta, _config) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    if error = meta[:error] do
      Span.set_attribute(ctx, ErrorAttributes.error_type(), error_type(error))
      Span.set_status(ctx, OpenTelemetry.status(:error, format_error(error)))
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
    Span.set_attribute(ctx, ErrorAttributes.error_type(), error_type(exception))
    Span.record_exception(ctx, exception, stacktrace)

    Span.set_status(
      ctx,
      OpenTelemetry.status(:error, Exception.format_banner(kind, reason, stacktrace))
    )

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  defp error_type(%{__struct__: module}), do: to_string(module)
  defp error_type(%{__exception__: true} = exception), do: to_string(exception.__struct__)
  defp error_type(error) when is_atom(error), do: to_string(error)

  defp error_type(error) do
    # Emit telemetry so users can hook loggers or monitoring
    :telemetry.execute(
      [:commanded, :opentelemetry, :warning],
      %{count: 1},
      %{
        message: "Unknown error type encountered, returning UNKNOWN",
        error: error,
        tracer_id: @tracer_id
      }
    )

    "UNKNOWN"
  end

  defp format_error(%{__exception__: true} = exception), do: Exception.message(exception)
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  # Clears stale context when metadata has no traceparent to prevent Event B
  # from incorrectly becoming a child of Event A's trace.
  defp attach_ctx(nil) do
    :otel_ctx.attach(:otel_ctx.new())
  end

  defp attach_ctx(metadata) when is_map(metadata) do
    headers = build_headers_from_metadata(metadata)

    if headers != [] do
      fresh_ctx = :otel_ctx.new()
      extracted_ctx = :otel_propagator_text_map.extract_to(fresh_ctx, headers)
      :otel_ctx.attach(extracted_ctx)
    else
      :otel_ctx.attach(:otel_ctx.new())
    end
  end

  # Extract span context from W3C headers for :link span relationship.
  # Returns context without setting as current (unlike attach_ctx/1).
  defp extract_span_context_for_link(nil), do: nil

  defp extract_span_context_for_link(metadata) when is_map(metadata) do
    headers = build_headers_from_metadata(metadata)

    if headers != [] do
      fresh_ctx = :otel_ctx.new()
      extracted_ctx = :otel_propagator_text_map.extract_to(fresh_ctx, headers)
      :otel_tracer.current_span_ctx(extracted_ctx)
    else
      nil
    end
  end

  defp build_headers_from_metadata(metadata) do
    []
    |> maybe_add_header(metadata, "traceparent")
    |> maybe_add_header(metadata, "tracestate")
  end

  defp maybe_add_header(headers, metadata, key) do
    case metadata[key] do
      nil -> headers
      value -> [{key, value} | headers]
    end
  end

  defp module_name(nil), do: nil
  defp module_name(module) when is_atom(module), do: inspect(module)
  defp module_name(_), do: nil

  defp put_links(span_opts, []), do: span_opts
  defp put_links(span_opts, links), do: Map.put(span_opts, :links, links)
end
