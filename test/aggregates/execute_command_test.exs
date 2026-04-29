defmodule Commanded.Aggregates.ExecuteCommandTest do
  use ExUnit.Case

  import Commanded.Helpers.ProcessHelper, only: [shutdown_aggregate: 3]

  alias Commanded.Aggregates.{Aggregate, ExecutionContext}
  alias Commanded.Commands.{TimeoutAggregateRoot, TimeoutCommand, TimeoutCommandHandler}
  alias Commanded.ExampleDomain.{BankAccount, BankApp, OpenAccountHandler}
  alias Commanded.ExampleDomain.BankAccount.Commands.OpenAccount
  alias Commanded.ExampleDomain.BankAccount.Events.BankAccountOpened
  alias Commanded.Helpers.Wait
  alias Commanded.TestSupport.RetryStopOnceAggregate
  alias Commanded.TestSupport.RetryStopOnceAggregate.Command, as: RetryStopOnceCommand
  alias Commanded.{DefaultApp, Registration, UUID}

  defmodule CrashCommand do
    defstruct [:uuid]
  end

  defmodule CrashBeforeExecuteAggregate do
    alias Commanded.Aggregates.ExecutionContext

    defstruct []

    def before_execute(_aggregate_state, %ExecutionContext{}), do: Process.exit(self(), :boom)
    def execute(%__MODULE__{}, %CrashCommand{}), do: []
  end

  setup do
    start_supervised!(BankApp)
    start_supervised!(DefaultApp)
    start_supervised!(RetryStopOnceAggregate.Tracker)

    :ok
  end

  test "execute command against an aggregate" do
    account_number = UUID.uuid4()

    {:ok, ^account_number} = open_aggregate(BankAccount, account_number)

    command = %OpenAccount{account_number: account_number, initial_balance: 1_000}
    context = %ExecutionContext{command: command, handler: BankAccount, function: :open_account}

    {:ok, 1, events, _aggregate_state} =
      Aggregate.execute(BankApp, BankAccount, account_number, context)

    assert events == [%BankAccountOpened{account_number: account_number, initial_balance: 1_000}]

    shutdown_aggregate(BankApp, BankAccount, account_number)

    # reload aggregate to fetch persisted events from event store and rebuild state by applying saved events
    {:ok, ^account_number} = open_aggregate(BankAccount, account_number)

    assert Aggregate.aggregate_version(BankApp, BankAccount, account_number) == 1

    assert Aggregate.aggregate_state(BankApp, BankAccount, account_number) == %BankAccount{
             account_number: account_number,
             balance: 1_000,
             state: :active
           }
  end

  test "execute command via a command handler" do
    account_number = UUID.uuid4()

    {:ok, ^account_number} = open_aggregate(BankAccount, account_number)

    command = %OpenAccount{account_number: account_number, initial_balance: 1_000}
    context = %ExecutionContext{command: command, handler: OpenAccountHandler, function: :handle}

    {:ok, 1, events, _aggregate_state} =
      Aggregate.execute(BankApp, BankAccount, account_number, context)

    assert events == [%BankAccountOpened{account_number: account_number, initial_balance: 1_000}]

    shutdown_aggregate(BankApp, BankAccount, account_number)

    # Reload aggregate to fetch persisted events from event store and rebuild state by applying saved events
    {:ok, ^account_number} = open_aggregate(BankAccount, account_number)

    assert Aggregate.aggregate_version(BankApp, BankAccount, account_number) == 1

    assert Aggregate.aggregate_state(BankApp, BankAccount, account_number) == %BankAccount{
             account_number: account_number,
             balance: 1_000,
             state: :active
           }
  end

  test "aggregate raising an exception should not persist pending events or state" do
    account_number = UUID.uuid4()

    {:ok, ^account_number} = open_aggregate(BankAccount, account_number)

    command = %OpenAccount{account_number: account_number, initial_balance: 1_000}
    context = %ExecutionContext{command: command, handler: OpenAccountHandler, function: :handle}

    {:ok, 1, _events, _aggregate_state} =
      Aggregate.execute(BankApp, BankAccount, account_number, context)

    state_before = Aggregate.aggregate_state(BankApp, BankAccount, account_number)

    assert_aggregate_exit(BankApp, BankAccount, account_number, fn ->
      command = %OpenAccount{account_number: account_number, initial_balance: 1}

      context = %ExecutionContext{
        command: command,
        handler: OpenAccountHandler,
        function: :handle
      }

      Aggregate.execute(BankApp, BankAccount, account_number, context)
    end)

    {:ok, ^account_number} = open_aggregate(BankAccount, account_number)

    assert state_before == Aggregate.aggregate_state(BankApp, BankAccount, account_number)
  end

  test "returns aggregate_stopped when aggregate stops after being opened" do
    aggregate_uuid = UUID.uuid4()

    assert {:ok, ^aggregate_uuid} =
             Commanded.Aggregates.Supervisor.open_aggregate(
               DefaultApp,
               RetryStopOnceAggregate,
               aggregate_uuid
             )

    context = %ExecutionContext{
      command: %RetryStopOnceCommand{uuid: aggregate_uuid},
      handler: RetryStopOnceAggregate,
      function: :execute,
      before_execute: :before_execute
    }

    assert {:exit, {:normal, :aggregate_stopped}} =
             Aggregate.execute(DefaultApp, RetryStopOnceAggregate, aggregate_uuid, context)
  end

  test "returns aggregate_execution_timeout when command execution exceeds the timeout" do
    aggregate_uuid = UUID.uuid4()

    assert {:ok, ^aggregate_uuid} =
             Commanded.Aggregates.Supervisor.open_aggregate(
               DefaultApp,
               TimeoutAggregateRoot,
               aggregate_uuid
             )

    context = %ExecutionContext{
      command: %TimeoutCommand{aggregate_uuid: aggregate_uuid, sleep_in_ms: 200},
      handler: TimeoutCommandHandler,
      function: :handle
    }

    assert {:error, :aggregate_execution_timeout} =
             Aggregate.execute(DefaultApp, TimeoutAggregateRoot, aggregate_uuid, context, 50)
  end

  test "returns aggregate_execution_failed with the exit reason when the aggregate exits abnormally" do
    aggregate_uuid = UUID.uuid4()

    assert {:ok, ^aggregate_uuid} =
             Commanded.Aggregates.Supervisor.open_aggregate(
               DefaultApp,
               CrashBeforeExecuteAggregate,
               aggregate_uuid
             )

    context = %ExecutionContext{
      command: %CrashCommand{uuid: aggregate_uuid},
      handler: CrashBeforeExecuteAggregate,
      function: :execute,
      before_execute: :before_execute
    }

    assert {:error, :aggregate_execution_failed, :boom} =
             Aggregate.execute(DefaultApp, CrashBeforeExecuteAggregate, aggregate_uuid, context)
  end

  describe "command dispatch return" do
    alias Commanded.Aggregates.ReturnValue.Command
    alias Commanded.Aggregates.ReturnValue.Event

    test "should allow `:ok` return value" do
      assert_no_events(fn %Command{} -> :ok end)
    end

    test "should allow `nil` return value" do
      assert_no_events(fn %Command{} -> nil end)
    end

    test "should allow `[]` return value" do
      assert_no_events(fn %Command{} -> [] end)
    end

    test "should allow single events return value" do
      assert_event_result(fn %Command{id: id} -> %Event{id: id} end)
    end

    test "should allow event list return value" do
      assert_event_result(fn %Command{id: id} -> [%Event{id: id}] end)
    end

    test "should allow `{:ok, event}` tagged tuple return value" do
      assert_event_result(fn %Command{id: id} -> {:ok, %Event{id: id}} end)
    end

    test "should allow `{:ok, [event]}` tagged tuple return value" do
      assert_event_result(fn %Command{id: id} -> {:ok, [%Event{id: id}]} end)
    end
  end

  defp assert_no_events(command_fun) do
    id = UUID.uuid4()

    assert {:ok, 0, [], _aggregate_state} = execute_aggregate_command(id, command_fun)
  end

  defp assert_event_result(command_fun) do
    alias Commanded.Aggregates.ReturnValue.Event

    id = UUID.uuid4()

    assert {:ok, 1, [%Event{id: ^id}], _aggregate_state} =
             execute_aggregate_command(id, command_fun)
  end

  defp execute_aggregate_command(id, command_fun) do
    alias Commanded.Aggregates.ReturnValue.Command
    alias Commanded.Aggregates.ReturnValue.ExampleAggregate

    {:ok, ^id} = open_aggregate(ExampleAggregate, id)

    context = %ExecutionContext{
      command: %Command{id: id, fun: command_fun},
      handler: ExampleAggregate,
      function: :execute
    }

    Aggregate.execute(BankApp, ExampleAggregate, id, context)
  end

  defp assert_aggregate_exit(application, aggregate_module, aggregate_uuid, fun) do
    pid = spawn(fun)

    # Wait for spawned function to terminate
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}

    name = {application, aggregate_module, aggregate_uuid}

    # Wait for the aggregate process to terminate
    Wait.until(fn ->
      assert Registration.whereis_name(application, name) == :undefined
    end)
  end

  defp open_aggregate(module, id) do
    Commanded.Aggregates.Supervisor.open_aggregate(BankApp, module, id)
  end
end
