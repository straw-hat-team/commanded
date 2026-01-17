defmodule Commanded.OpenTelemetry.EventHandler do
  @moduledoc false

  alias Commanded.OpenTelemetry.CommandedAttributes
  alias Commanded.OpenTelemetry.Helpers
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
          Helpers.attach_ctx(nil)
          if link_ctx, do: [OpenTelemetry.link(link_ctx)], else: []

        :child ->
          Helpers.attach_ctx(recorded_event.metadata)
          []

        :none ->
          Helpers.attach_ctx(nil)
          []
      end

    handler_module_name = Helpers.module_name(meta.handler_module)

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

    # OTel semconv: span name = "{operation.name} {destination.name}"
    span_name = "handle #{handler_module_name}"

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
    Helpers.attach_ctx(nil)

    handler_module_name = Helpers.module_name(meta.handler_module)

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

    # OTel semconv: span name = "{operation.name} {destination.name}"
    span_name = "batch #{handler_module_name}"

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

  # Extract span context from W3C headers for :link span relationship.
  # Returns context without setting as current (unlike attach_ctx/1).
  defp extract_span_context_for_link(nil), do: nil

  defp extract_span_context_for_link(metadata) when is_map(metadata) do
    headers = Helpers.build_headers_from_metadata(metadata)

    if headers != [] do
      fresh_ctx = :otel_ctx.new()
      extracted_ctx = :otel_propagator_text_map.extract_to(fresh_ctx, headers)
      :otel_tracer.current_span_ctx(extracted_ctx)
    else
      nil
    end
  end

  defp put_links(span_opts, []), do: span_opts
  defp put_links(span_opts, links), do: Map.put(span_opts, :links, links)
end
