defmodule Commanded.OpenTelemetry.Helpers do
  @moduledoc false

  alias Commanded.OpenTelemetry.CommandedAttributes
  alias OpenTelemetry.SemConv.Incubating.DBAttributes
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes
  alias OpenTelemetry.SemConv.Incubating.PeerAttributes
  alias OpenTelemetry.SemConv.ServerAttributes
  alias OpenTelemetry.Span

  def extract_propagated_ctx(nil), do: {[], :undefined}

  def extract_propagated_ctx(metadata) when is_map(metadata) do
    headers = build_headers_from_metadata(metadata)
    if headers == [], do: {[], :undefined}, else: extract_to_ctx(headers)
  end

  defp extract_to_ctx(headers) do
    ctx =
      :otel_ctx.new()
      |> :otel_propagator_text_map.extract_to(headers)

    span_ctx = :otel_tracer.current_span_ctx(ctx)
    baggage = :otel_baggage.get_all(ctx)

    case {span_ctx, map_size(baggage)} do
      {:undefined, 0} -> {[], :undefined}
      {:undefined, _} -> {[], ctx}
      {span_ctx, _} -> {[OpenTelemetry.link(span_ctx)], ctx}
    end
  end

  def clear_ctx do
    :otel_ctx.attach(:otel_ctx.new())
  end

  defp build_headers_from_metadata(metadata) do
    []
    |> maybe_add_header(metadata, "traceparent")
    |> maybe_add_header(metadata, "tracestate")
    |> maybe_add_header(metadata, "baggage")
  end

  defp maybe_add_header(headers, metadata, key) do
    case metadata[key] do
      nil -> headers
      value -> [{key, value} | headers]
    end
  end

  # Emits telemetry for unknown error types so users can detect unexpected
  # error formats in their monitoring and fix them.
  def to_error_type(error, _tracer_id) when is_struct(error), do: inspect(error.__struct__)

  def to_error_type(error, _tracer_id) when is_atom(error), do: inspect(error)

  def to_error_type(error, tracer_id) do
    :telemetry.execute(
      [:commanded, :opentelemetry, :warning],
      %{count: 1},
      %{
        message: "Unknown error type encountered, returning UNKNOWN",
        error: error,
        tracer_id: tracer_id
      }
    )

    "UNKNOWN"
  end

  def format_error(%{__exception__: true} = exception), do: Exception.message(exception)
  def format_error(error) when is_binary(error), do: error
  def format_error(error), do: inspect(error)

  def set_error_status(ctx, error, event_name, measurements, meta, config, tracer_id) do
    status_code =
      case Keyword.get(config, :error_status) do
        nil -> :error
        fun when is_function(fun, 4) -> fun.(event_name, measurements, meta, config)
      end

    apply_error_status(ctx, status_code, error, tracer_id)
  end

  defp apply_error_status(_ctx, nil, _error, _tracer_id), do: :ok

  defp apply_error_status(ctx, :error, error, _tracer_id) do
    Span.set_status(ctx, OpenTelemetry.status(:error, format_error(error)))
  end

  defp apply_error_status(ctx, code, _error, _tracer_id) when code in [:unset, :ok] do
    Span.set_status(ctx, OpenTelemetry.status(code))
  end

  defp apply_error_status(ctx, status_code, error, tracer_id) do
    :telemetry.execute(
      [:commanded, :opentelemetry, :warning],
      %{count: 1},
      %{
        message: "Unknown error status encountered, falling back to error status",
        error: error,
        error_status: status_code,
        tracer_id: tracer_id
      }
    )

    Span.set_status(ctx, OpenTelemetry.status(:error, format_error(error)))
  end

  def module_name(nil), do: nil
  def module_name(module) when is_atom(module), do: inspect(module)
  def module_name(_), do: nil

  def struct_name(%name{}), do: inspect(name)
  def struct_name(_), do: nil

  def maybe_add_connection_attributes(attrs, [_ | _] = config) do
    attrs
    |> maybe_add_attr(ServerAttributes.server_address(), config[:hostname])
    |> maybe_add_attr(ServerAttributes.server_port(), config[:port])
    |> maybe_add_attr(DBAttributes.db_namespace(), config[:database])
    |> maybe_add_attr(PeerAttributes.peer_service(), config[:database])
  end

  def maybe_add_connection_attributes(attrs, _config), do: attrs

  def maybe_add_attr(attrs, _key, nil), do: attrs
  def maybe_add_attr(attrs, key, value), do: [{key, value} | attrs]

  def maybe_add_operation_type(attrs, nil), do: attrs

  def maybe_add_operation_type(attrs, type),
    do: [{MessagingAttributes.messaging_operation_type(), type} | attrs]

  def maybe_add_destination_name(attrs, nil), do: attrs

  def maybe_add_destination_name(attrs, name),
    do: [{MessagingAttributes.messaging_destination_name(), name} | attrs]

  def maybe_add_stream_uuid(attrs, nil), do: attrs

  def maybe_add_stream_uuid(attrs, uuid),
    do: [{CommandedAttributes.commanded_stream_uuid(), uuid} | attrs]

  def maybe_add_expected_version(attrs, nil), do: attrs

  def maybe_add_expected_version(attrs, version),
    do: [{CommandedAttributes.commanded_expected_version(), version} | attrs]

  def maybe_add_event_count(attrs, nil), do: attrs

  def maybe_add_event_count(attrs, count),
    do: [{CommandedAttributes.commanded_event_count(), count} | attrs]

  def maybe_add_subscription_name(attrs, nil), do: attrs

  def maybe_add_subscription_name(attrs, name) do
    [
      {MessagingAttributes.messaging_destination_subscription_name(), name},
      {CommandedAttributes.commanded_subscription_name(), name}
      | attrs
    ]
  end

  def maybe_add_source_uuid(attrs, nil), do: attrs

  def maybe_add_source_uuid(attrs, uuid),
    do: [{CommandedAttributes.commanded_source_uuid(), uuid} | attrs]

  def to_destination_name(nil), do: nil
  def to_destination_name(name) when is_binary(name), do: name
  def to_destination_name(name) when is_atom(name), do: inspect(name)
  def to_destination_name(_), do: nil
end
