defmodule Commanded.Application.TelemetryTest do
  use ExUnit.Case

  alias Commanded.Aggregates.{Lifespan, LifespanAggregate}
  alias Commanded.Aggregates.LifespanAggregate.Command, as: LifespanCommand
  alias Commanded.DefaultApp
  alias Commanded.Middleware.Commands.Fail
  alias Commanded.Middleware.Commands.IncrementCount
  alias Commanded.Middleware.Commands.RaiseError
  alias Commanded.UUID

  setup do
    start_supervised!(DefaultApp)
    attach_telemetry()

    :ok
  end

  defmodule TestRouter do
    use Commanded.Commands.Router

    alias Commanded.Middleware.Commands.CommandHandler
    alias Commanded.Middleware.Commands.CounterAggregateRoot

    dispatch IncrementCount,
      to: CommandHandler,
      aggregate: CounterAggregateRoot,
      identity: :aggregate_uuid

    dispatch RaiseError,
      to: CommandHandler,
      aggregate: CounterAggregateRoot,
      identity: :aggregate_uuid
  end

  defmodule RetryExhaustionRouter do
    use Commanded.Commands.Router

    alias Commanded.Aggregates.Lifespan
    alias Commanded.Aggregates.LifespanAggregate
    alias Commanded.Aggregates.LifespanAggregate.Command

    dispatch [Command],
      to: LifespanAggregate,
      identity: :uuid,
      lifespan: Lifespan
  end

  test "emit `[:commanded, :application, :dispatch, :start | :stop]` event" do
    command = %IncrementCount{aggregate_uuid: UUID.uuid4()}

    assert :ok = TestRouter.dispatch(command, application: DefaultApp)

    assert_receive {[:commanded, :application, :dispatch, :start], 1, _meas, _meta}
    assert_receive {[:commanded, :aggregate, :execute, :start], 2, _meas, _meta}
    assert_receive {[:commanded, :aggregate, :execute, :stop], 3, _meas, _meta}
    assert_receive {[:commanded, :application, :dispatch, :stop], 4, _meas, meta}

    assert %{application: DefaultApp, error: nil, execution_context: %{command: ^command}} = meta
  end

  test "emit `[:commanded, :application, :dispatch, :start | :stop]` event on error" do
    command = %RaiseError{aggregate_uuid: UUID.uuid4()}
    error = %RuntimeError{message: "failed"}

    assert {:error, ^error} = TestRouter.dispatch(command, application: DefaultApp)

    assert_receive {[:commanded, :application, :dispatch, :start], 1, _meas, _meta}
    assert_receive {[:commanded, :aggregate, :execute, :start], 2, _meas, _meta}
    assert_receive {[:commanded, :aggregate, :execute, :exception], 3, _meas, _meta}
    assert_receive {[:commanded, :application, :dispatch, :stop], 4, _meas, meta}

    assert %{application: DefaultApp, error: ^error, execution_context: %{command: ^command}} =
             meta
  end

  test "emit `[:commanded, :application, :dispatch, :start | :stop]` event on unregistered command" do
    command = %Fail{aggregate_uuid: UUID.uuid4()}
    error = :unregistered_command

    assert {:error, ^error} = TestRouter.dispatch(command, application: DefaultApp)

    assert_receive {[:commanded, :application, :dispatch, :start], 1, _meas, _meta}

    assert_receive {[:commanded, :application, :dispatch, :stop], 2, _meas, meta}

    assert %{application: DefaultApp, error: ^error, execution_context: %{command: ^command}} =
             meta
  end

  test "emit dispatch stop telemetry when dispatcher retries are exhausted" do
    aggregate_uuid = UUID.uuid4()

    {:ok, ^aggregate_uuid} =
      Commanded.Aggregates.Supervisor.open_aggregate(
        DefaultApp,
        LifespanAggregate,
        aggregate_uuid
      )

    command = %LifespanCommand{uuid: aggregate_uuid, action: :noop, lifespan: :stop}

    results =
      dispatch_concurrently(fn ->
        RetryExhaustionRouter.dispatch(command, application: DefaultApp, retry_attempts: 0)
      end)

    assert Enum.any?(results, &match?({:ok, {:error, :too_many_attempts}}, &1))

    assert Enum.all?(results, fn
             {:ok, :ok} -> true
             {:ok, {:error, :too_many_attempts}} -> true
             _ -> false
           end)

    events = collect_dispatch_events(length(results))

    starts =
      Enum.count(events, &match?({[:commanded, :application, :dispatch, :start], _, _, _}, &1))

    stop_errors =
      for {[:commanded, :application, :dispatch, :stop], _, _, %{error: error}} <- events do
        error
      end

    assert starts == length(results)
    assert length(stop_errors) == length(results)
    assert :too_many_attempts in stop_errors
  end

  defp attach_telemetry do
    agent = start_supervised!({Agent, fn -> 1 end})

    :telemetry.attach_many(
      "test-handler",
      [
        [:commanded, :aggregate, :execute, :start],
        [:commanded, :aggregate, :execute, :stop],
        [:commanded, :aggregate, :execute, :exception],
        [:commanded, :application, :dispatch, :start],
        [:commanded, :application, :dispatch, :stop]
      ],
      fn event_name, measurements, metadata, reply_to ->
        num = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
        send(reply_to, {event_name, num, measurements, metadata})
      end,
      self()
    )

    on_exit(fn ->
      :telemetry.detach("test-handler")
    end)
  end

  defp collect_dispatch_events(expected_stops, events \\ []) do
    stop_count =
      Enum.count(events, fn
        {[:commanded, :application, :dispatch, :stop], _, _, _} -> true
        _ -> false
      end)

    if stop_count == expected_stops do
      Enum.reverse(events)
    else
      assert_receive event, 1_000

      case event do
        {[:commanded, :application, :dispatch, _], _, _, _} ->
          collect_dispatch_events(expected_stops, [event | events])

        _ ->
          collect_dispatch_events(expected_stops, events)
      end
    end
  end

  defp dispatch_concurrently(fun, count \\ 10) do
    1..count
    |> Task.async_stream(fn _ -> fun.() end, ordered: false, timeout: 5_000)
    |> Enum.to_list()
  end
end
