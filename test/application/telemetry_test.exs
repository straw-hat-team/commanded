defmodule Commanded.Application.TelemetryTest do
  use ExUnit.Case

  alias Commanded.DefaultApp
  alias Commanded.Commands.{TimeoutCommand, TimeoutRouter}
  alias Commanded.Middleware.Commands.Fail
  alias Commanded.Middleware.Commands.IncrementCount
  alias Commanded.Middleware.Commands.RaiseError
  alias Commanded.TestSupport.RetryStopOnceAggregate
  alias Commanded.TestSupport.RetryStopOnceAggregate.Command, as: RetryStopOnceCommand
  alias Commanded.UUID

  setup do
    start_supervised!(RetryStopOnceAggregate.Tracker)
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

    alias Commanded.TestSupport.RetryStopOnceAggregate
    alias Commanded.TestSupport.RetryStopOnceAggregate.Command

    dispatch [Command],
      to: RetryStopOnceAggregate,
      identity: :uuid,
      before_execute: :before_execute
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

    command = %RetryStopOnceCommand{uuid: aggregate_uuid}

    assert {:error, :too_many_attempts} =
             RetryExhaustionRouter.dispatch(command, application: DefaultApp, retry_attempts: 0)

    assert_receive {[:commanded, :application, :dispatch, :start], _, _, _}

    assert_receive {[:commanded, :application, :dispatch, :stop], _, _,
                    %{error: :too_many_attempts}}
  end

  test "emit a single aggregate execute attempt when command execution times out" do
    command = %TimeoutCommand{aggregate_uuid: UUID.uuid4(), sleep_in_ms: 2_000}

    assert {:error, error} = TimeoutRouter.dispatch(command, application: DefaultApp)
    assert error in [:aggregate_execution_failed, :aggregate_execution_timeout]

    assert_receive {[:commanded, :application, :dispatch, :start], _, _, _}
    assert_receive {[:commanded, :aggregate, :execute, :start], _, _, _}

    refute_receive {[:commanded, :aggregate, :execute, :start], _, _, _}, 200

    assert_receive {[:commanded, :application, :dispatch, :stop], _, _,
                    %{error: ^error}}
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
end
