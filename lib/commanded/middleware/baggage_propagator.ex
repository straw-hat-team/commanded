if Code.ensure_loaded?(:otel_propagator_text_map) do
  defmodule Commanded.Middleware.BaggagePropagator do
    @moduledoc """
    A middleware for propagating W3C Baggage to Event Handlers.

    This middleware captures the current baggage from the OpenTelemetry context
    and stores it in event metadata following the
    [W3C Baggage](https://www.w3.org/TR/baggage/) specification, allowing event
    handlers to read user-defined name/value pairs that travel alongside trace
    context.

    Baggage and W3C Trace Context are independent specifications.
    `Commanded.Middleware.TraceContextPropagator` propagates `traceparent` and
    `tracestate`; this middleware propagates `baggage`. Use both together to
    propagate the full OpenTelemetry context.

    ## W3C Baggage

    The middleware stores baggage using the standard W3C header name:

      * `baggage` - A comma-separated list of `key=value` pairs, with optional
        per-entry metadata (e.g. `userId=alice,serverNode=DF%2028,isProduction=false`).

    ## Persistence considerations

    Baggage entries are written into event metadata and therefore persisted in
    the event store for the lifetime of the stream. Do not place PII, secrets,
    or unbounded values into baggage when this middleware is enabled. Filter or
    redact at the producer site (before `OpenTelemetry.Baggage.set/1`) if
    necessary.

    ## Dependencies

    This middleware requires `opentelemetry_api` to be installed and the
    `baggage` propagator to be present in the global text map propagator
    composite (the OpenTelemetry SDK's default is `[trace_context, baggage]`).

        {:opentelemetry_api, "~> 1.0"}

    ## Usage

    ```elixir
    defmodule BankRouter do
      use Commanded.Commands.Router

      middleware Commanded.Middleware.TraceContextPropagator
      middleware Commanded.Middleware.BaggagePropagator

      dispatch [OpenAccount, DepositMoney],
        to: BankAccount,
        identity: :account_number
    end
    ```
    """

    @behaviour Commanded.Middleware

    alias Commanded.Middleware.Pipeline

    @doc """
    Injects the W3C `baggage` header into the command pipeline metadata.

    Called before command dispatch to capture the current baggage. If no
    baggage is set on the current OpenTelemetry context, the pipeline is
    returned unchanged.
    """
    @impl true
    def before_dispatch(%Pipeline{} = pipeline) do
      case :otel_propagator_text_map.inject([]) do
        [] ->
          pipeline

        headers ->
          maybe_assign(pipeline, "baggage", List.keyfind(headers, "baggage", 0))
      end
    end

    defp maybe_assign(pipeline, _key, nil), do: pipeline

    defp maybe_assign(pipeline, key, {_, value}),
      do: Pipeline.assign_metadata(pipeline, key, value)

    @doc false
    @impl true
    def after_dispatch(pipeline), do: pipeline

    @doc false
    @impl true
    def after_failure(pipeline), do: pipeline
  end
end
