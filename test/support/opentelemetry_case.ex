defmodule Commanded.OpenTelemetryCase do
  @moduledoc """
  ExUnit case template for tests that need to assert on OpenTelemetry spans.

  Use `async: false` since this modifies global OpenTelemetry state.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Commanded.OpenTelemetryCase

      require Record

      for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
        Record.defrecord(name, spec)
      end

      for {name, spec} <-
            Record.extract_all(from_lib: "opentelemetry_api/include/opentelemetry.hrl") do
        Record.defrecord(name, spec)
      end
    end
  end

  setup do
    :application.stop(:opentelemetry)
    :application.set_env(:opentelemetry, :tracer, :otel_tracer_default)

    :application.set_env(:opentelemetry, :processors, [
      {:otel_batch_processor, %{scheduled_delay_ms: 1, exporter: {:otel_exporter_pid, self()}}}
    ])

    :application.start(:opentelemetry)

    on_exit(fn ->
      commanded_events = [
        [:commanded, :event, :handle, :start],
        [:commanded, :event, :handle, :stop],
        [:commanded, :event, :handle, :exception],
        [:commanded, :event, :batch, :start],
        [:commanded, :event, :batch, :stop],
        [:commanded, :event, :batch, :exception],
        [:commanded, :aggregate, :execute, :start],
        [:commanded, :aggregate, :execute, :stop],
        [:commanded, :aggregate, :execute, :exception]
      ]

      for event <- commanded_events,
          handler <- :telemetry.list_handlers(event) do
        :telemetry.detach(handler.id)
      end
    end)

    :ok
  end
end
