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
    command_name = inspect(RetryStopOnceCommand)
    causation_id = UUID.uuid4()

    assert :ok = App.dispatch(command, retry_attempts: 1, command_uuid: causation_id)

    assert_receive {:aggregate_execute_start, ^aggregate_uuid}, 1_000
    assert_receive {:aggregate_execute_start, ^aggregate_uuid}, 1_000
    assert_receive {:aggregate_execute_stop, ^aggregate_uuid}, 1_000

    refute_receive {:aggregate_execute_stop, ^aggregate_uuid}, 200
    refute_receive {:aggregate_execute_start, ^aggregate_uuid}, 200

    assert {dispatch_span, execute_span} =
             collect_retry_spans(aggregate_uuid, command_name, causation_id)

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

  defp collect_spans(timeout_ms \\ 1_500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_spans([], deadline)
  end

  defp collect_spans(spans, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:span, span} ->
        collect_spans([span | spans], deadline)
    after
      remaining ->
        Enum.reverse(spans)
    end
  end

  defp collect_retry_spans(aggregate_uuid, command_name, causation_id) do
    collect_spans()
    |> Enum.group_by(&span(&1, :trace_id))
    |> Enum.find_value(fn {_trace_id, spans} ->
      dispatch_span =
        Enum.find(spans, &dispatch_span?(&1, command_name, causation_id))

      execute_span =
        Enum.find(spans, &execute_span?(&1, aggregate_uuid, command_name, causation_id))

      if dispatch_span && execute_span do
        {dispatch_span, execute_span}
      end
    end)
  end

  defp dispatch_span?(span, command_name, causation_id) do
    attributes = span_attributes(span)

    String.starts_with?(span(span, :name), "dispatch ") and
      attributes[:"commanded.command"] == command_name and
      attributes[:"messaging.message.id"] == causation_id
  end

  defp execute_span?(span, aggregate_uuid, command_name, causation_id) do
    attributes = span_attributes(span)

    String.starts_with?(span(span, :name), "execute ") and
      attributes[:"commanded.aggregate.uuid"] == aggregate_uuid and
      attributes[:"commanded.command"] == command_name and
      attributes[:"messaging.message.id"] == causation_id
  end

  defp span_attributes(span) do
    span(span, :attributes)
    |> :otel_attributes.map()
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
