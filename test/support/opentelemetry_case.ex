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
    previous_env = Application.get_all_env(:opentelemetry)
    previously_started? = started?(:opentelemetry)

    restart_opentelemetry(
      tracer: :otel_tracer_default,
      processors: [
        {:otel_batch_processor, %{scheduled_delay_ms: 1, exporter: {:otel_exporter_pid, self()}}}
      ]
    )

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
        [:commanded, :aggregate, :execute, :exception],
        [:commanded, :aggregate, :load, :start],
        [:commanded, :aggregate, :load, :stop],
        [:commanded, :aggregate, :populate, :start],
        [:commanded, :aggregate, :populate, :stop],
        [:commanded, :aggregate, :snapshot, :start],
        [:commanded, :aggregate, :snapshot, :stop],
        [:commanded, :aggregate, :snapshot, :exception],
        [:commanded, :application, :dispatch, :start],
        [:commanded, :application, :dispatch, :stop],
        [:commanded, :application, :dispatch, :exception]
      ]

      for event <- commanded_events,
          handler <- :telemetry.list_handlers(event) do
        :telemetry.detach(handler.id)
      end

      restore_opentelemetry(previous_env, previously_started?)
    end)

    :ok
  end

  defp started?(application) do
    Enum.any?(Application.started_applications(), fn {started_application, _description, _version} ->
      started_application == application
    end)
  end

  defp restart_opentelemetry(env) do
    stop_opentelemetry()

    Enum.each(env, fn {key, value} ->
      Application.put_env(:opentelemetry, key, value)
    end)

    Application.start(:opentelemetry)
  end

  defp restore_opentelemetry(previous_env, previously_started?) do
    stop_opentelemetry()

    current_keys =
      :opentelemetry
      |> Application.get_all_env()
      |> Keyword.keys()

    Enum.each(current_keys -- Keyword.keys(previous_env), fn key ->
      Application.delete_env(:opentelemetry, key)
    end)

    Enum.each(previous_env, fn {key, value} ->
      Application.put_env(:opentelemetry, key, value)
    end)

    if previously_started? do
      Application.start(:opentelemetry)
    end
  end

  defp stop_opentelemetry do
    case Application.stop(:opentelemetry) do
      :ok -> :ok
      {:error, {:not_started, :opentelemetry}} -> :ok
    end
  end
end
