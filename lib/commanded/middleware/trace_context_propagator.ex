if Code.ensure_loaded?(:otel_propagator_text_map) do
  defmodule Commanded.Middleware.TraceContextPropagator do
    @moduledoc """
    A middleware for propagating W3C Trace Context to Event Handlers.

    This middleware captures the current span context and stores it in event metadata
    following the [W3C Trace Context](https://www.w3.org/TR/trace-context-2/) specification,
    allowing event handlers to create proper span links or parent-child relationships.

    ## W3C Trace Context

    The middleware stores trace context using the standard W3C header names:

      * `traceparent` - Contains version, trace-id, parent-id (span-id), and trace-flags
      * `tracestate` - Vendor-specific key-value pairs (optional, only set if present)

    Example traceparent: `00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01`

    ## Dependencies

    This middleware requires `opentelemetry_api` to be installed:

        {:opentelemetry_api, "~> 1.0"}

    ## Usage

    ```elixir
    defmodule BankRouter do
      use Commanded.Commands.Router

      middleware Commanded.Middleware.TraceContextPropagator

      dispatch [OpenAccount, DepositMoney],
        to: BankAccount,
        identity: :account_number
    end
    ```
    """

    @behaviour Commanded.Middleware

    alias Commanded.Middleware.Pipeline

    @doc false
    def before_dispatch(%Pipeline{} = pipeline) do
      case :otel_propagator_text_map.inject([]) do
        [] ->
          pipeline

        headers ->
          pipeline
          |> maybe_assign("traceparent", List.keyfind(headers, "traceparent", 0))
          |> maybe_assign("tracestate", List.keyfind(headers, "tracestate", 0))
      end
    end

    defp maybe_assign(pipeline, _key, nil), do: pipeline

    defp maybe_assign(pipeline, key, {_, value}),
      do: Pipeline.assign_metadata(pipeline, key, value)

    def after_dispatch(pipeline), do: pipeline

    def after_failure(pipeline), do: pipeline
  end
end
