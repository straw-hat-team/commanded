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
    semconv_env = %{
      "OTEL_SEMCONV_STABILITY_OPT_IN" => System.get_env("OTEL_SEMCONV_STABILITY_OPT_IN"),
      "OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN" =>
        System.get_env("OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN")
    }

    clear_semconv_env()

    :application.stop(:opentelemetry)
    :application.set_env(:opentelemetry, :tracer, :otel_tracer_default)

    :application.set_env(:opentelemetry, :processors, [
      {:otel_batch_processor, %{scheduled_delay_ms: 1}}
    ])

    :application.start(:opentelemetry)
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())

    on_exit(fn ->
      restore_semconv_env(semconv_env)

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
    end)

    :ok
  end

  def put_semconv_stability_opt_in(value) when is_binary(value) do
    System.put_env("OTEL_SEMCONV_STABILITY_OPT_IN", value)
  end

  def put_semconv_stability_opt_in(nil) do
    System.delete_env("OTEL_SEMCONV_STABILITY_OPT_IN")
  end

  def put_exception_signal_opt_in(value) when is_binary(value) do
    System.put_env("OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN", value)
  end

  def put_exception_signal_opt_in(nil) do
    System.delete_env("OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN")
  end

  defp clear_semconv_env do
    System.delete_env("OTEL_SEMCONV_STABILITY_OPT_IN")
    System.delete_env("OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN")
  end

  defp restore_semconv_env(env) do
    Enum.each(env, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
