defmodule Commanded.OpenTelemetry.DispatcherRetryTest do
  use Commanded.OpenTelemetryCase, async: false

  alias Commanded.OpenTelemetry.Aggregate, as: OTelAggregate
  alias Commanded.OpenTelemetry.Application, as: OTelApplication
  alias Commanded.TestSupport.RetryStopOnceAggregate
  alias Commanded.TestSupport.RetryStopOnceAggregate.Command, as: RetryStopOnceCommand
  alias Commanded.UUID

  defmodule RetryRouter do
    use Commanded.Commands.Router

    alias Commanded.TestSupport.RetryStopOnceAggregate
    alias Commanded.TestSupport.RetryStopOnceAggregate.Command

    middleware Commanded.Middleware.TraceContextPropagator

    dispatch [Command],
      to: RetryStopOnceAggregate,
      identity: :uuid,
      before_execute: :before_execute
  end

  defmodule App do
    use Commanded.Application,
      otp_app: :commanded,
      event_store: [
        adapter: Commanded.EventStore.Adapters.InMemory,
        serializer: Commanded.Serialization.JsonSerializer
      ],
      pubsub: :local,
      registry: :local

    router(RetryRouter)
  end

  setup do
    start_supervised!(RetryStopOnceAggregate.Tracker)
    start_supervised!(App)

    detach_all_handlers()
    OTelApplication.setup()
    OTelAggregate.setup()

    attach_attempt_spy()

    :ok
  end

  test "aggregate-stop retries emit telemetry per attempt but export spans only for completed attempts" do
    aggregate_uuid = UUID.uuid4()
    command = %RetryStopOnceCommand{uuid: aggregate_uuid}

    assert :ok = App.dispatch(command, retry_attempts: 1)

    assert_receive {:aggregate_execute_start, ^aggregate_uuid}, 1_000
    assert_receive {:aggregate_execute_start, ^aggregate_uuid}, 1_000
    assert_receive {:aggregate_execute_stop, ^aggregate_uuid}, 1_000

    refute_receive {:aggregate_execute_stop, ^aggregate_uuid}, 200
    refute_receive {:aggregate_execute_start, ^aggregate_uuid}, 200

    {dispatch_span, execute_span} = collect_retry_spans()

    assert span(execute_span, :trace_id) == span(dispatch_span, :trace_id)
    assert span(execute_span, :parent_span_id) == span(dispatch_span, :span_id)
  end

  defp attach_attempt_spy do
    test_pid = self()

    :telemetry.attach_many(
      {__MODULE__, :attempt_spy},
      [
        [:commanded, :aggregate, :execute, :start],
        [:commanded, :aggregate, :execute, :stop]
      ],
      fn event, _measurements, meta, _config ->
        case event do
          [:commanded, :aggregate, :execute, :start] ->
            send(test_pid, {:aggregate_execute_start, meta.aggregate_uuid})

          [:commanded, :aggregate, :execute, :stop] ->
            send(test_pid, {:aggregate_execute_stop, meta.aggregate_uuid})
        end
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach({__MODULE__, :attempt_spy})
    end)
  end

  defp collect_retry_spans(timeout_ms \\ 1_500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_retry_spans(nil, nil, [], deadline)
  end

  defp collect_retry_spans(dispatch_span, execute_span, _seen, _deadline)
       when not is_nil(dispatch_span) and not is_nil(execute_span) do
    {dispatch_span, execute_span}
  end

  defp collect_retry_spans(dispatch_span, execute_span, seen, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:span, span} ->
        attributes = :otel_attributes.map(span(span, :attributes))
        span_name = span(span, :name)
        seen = [{span_name, attributes} | seen]

        dispatch_span =
          if String.starts_with?(span_name, "dispatch "), do: span, else: dispatch_span

        execute_span =
          if String.starts_with?(span_name, "execute "), do: span, else: execute_span

        collect_retry_spans(dispatch_span, execute_span, seen, deadline)
    after
      remaining ->
        flunk(
          "expected dispatch and execute spans, got: " <>
            inspect(Enum.reverse(seen))
        )
    end
  end

  defp detach_all_handlers do
    commanded_events = [
      [:commanded, :application, :dispatch, :start],
      [:commanded, :application, :dispatch, :stop],
      [:commanded, :application, :dispatch, :exception],
      [:commanded, :aggregate, :execute, :start],
      [:commanded, :aggregate, :execute, :stop],
      [:commanded, :aggregate, :execute, :exception]
    ]

    for event <- commanded_events,
        handler <- :telemetry.list_handlers(event) do
      :telemetry.detach(handler.id)
    end
  end
end
