defmodule Commanded.OpenTelemetry.Helpers do
  @moduledoc false

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

    case span_ctx do
      :undefined -> {[], :undefined}
      span_ctx -> {[OpenTelemetry.link(span_ctx)], ctx}
    end
  end

  def clear_ctx do
    :otel_ctx.attach(:otel_ctx.new())
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

  # Emits telemetry for unknown error types so users can detect unexpected
  # error formats in their monitoring and fix them.
  def to_error_type(%{__struct__: module}, _tracer_id), do: to_string(module)

  def to_error_type(%{__exception__: true} = exception, _tracer_id),
    do: to_string(exception.__struct__)

  def to_error_type(error, _tracer_id) when is_atom(error), do: to_string(error)

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

  def module_name(nil), do: nil
  def module_name(module) when is_atom(module), do: inspect(module)
  def module_name(_), do: nil

  def struct_name(%name{}), do: inspect(name)
  def struct_name(_), do: nil
end
