defmodule Commanded.OpenTelemetry.Helpers do
  @moduledoc false

  # Propagates trace context across process boundaries. Commanded runs aggregates
  # and event handlers in separate processes, so we extract W3C trace headers
  # from metadata to maintain parent-child span relationships.
  #
  # When nil or no headers, we clear context to prevent inheriting stale context
  # from the process dictionary (which could link unrelated traces).
  def attach_ctx(nil) do
    :otel_ctx.attach(:otel_ctx.new())
  end

  def attach_ctx(metadata) when is_map(metadata) do
    headers = build_headers_from_metadata(metadata)

    if headers != [] do
      fresh_ctx = :otel_ctx.new()
      extracted_ctx = :otel_propagator_text_map.extract_to(fresh_ctx, headers)
      :otel_ctx.attach(extracted_ctx)
    else
      :otel_ctx.attach(:otel_ctx.new())
    end
  end

  def build_headers_from_metadata(metadata) do
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
