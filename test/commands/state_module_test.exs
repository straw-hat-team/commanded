defmodule Commanded.Commands.StateModuleTest do
  use ExUnit.Case

  alias Commanded.Aggregates.{Aggregate, Supervisor}
  alias Commanded.Commands.StateModuleAggregate
  alias Commanded.Commands.StateModuleAggregate.{CreateCommand, UpdateCommand}
  alias Commanded.Commands.StateModuleAggregate.CreatedEvent
  alias Commanded.Commands.StateModuleAggregate.State
  alias Commanded.Commands.StateModuleRouter
  alias Commanded.{DefaultApp, EventStore}
  alias Commanded.EventStore.SnapshotData
  alias Commanded.UUID

  @dispatch_opts [application: DefaultApp]

  defp attach_snapshot_listener(application, aggregate_uuid) do
    ref = make_ref()
    subscriber = self()

    handler = fn _event, _measurements, meta, _config ->
      if meta[:aggregate_uuid] == aggregate_uuid and meta[:application] == application do
        send(subscriber, {:snapshot_complete, ref})
      end
    end

    :telemetry.attach(ref, [:commanded, :aggregate, :snapshot, :stop], handler, [])
    ref
  end

  defp wait_for_snapshot(ref, timeout \\ 5_000) do
    assert_receive {:snapshot_complete, ^ref}, timeout
    :telemetry.detach(ref)
  end

  setup do
    start_supervised!(DefaultApp)

    :ok
  end

  describe "routing with separate state module" do
    test "fetching aggregate state when GenServer is down fails cryptically if initial_state is omitted" do
      uuid = UUID.uuid4()

      # 1. Dispatch to create the stream and process
      assert :ok =
               StateModuleRouter.dispatch(
                 %CreateCommand{uuid: uuid, name: "Test"},
                 @dispatch_opts
               )

      # 2. Shut down the aggregate so it MUST be rebuilt from events
      :ok = Aggregate.shutdown(DefaultApp, StateModuleAggregate, uuid)

      # 3. This should throw a UndefinedFunctionError since the default is `struct(aggregate_module)`
      # The task will crash and the exit reason will be returned by our case statement
      # Under Task.shutdown with exit(reason) the error is deeply nested in the Task result
      Process.flag(:trap_exit, true)

      catch_exit(Commanded.aggregate_state(DefaultApp, StateModuleAggregate, uuid))

      assert_receive {:EXIT, _pid, {:undef, stacktrace}}

      assert [{Commanded.Commands.StateModuleAggregate, :__struct__, [], []} | _] = stacktrace

      # 4. This should work perfectly
      state =
        Commanded.aggregate_state(DefaultApp, StateModuleAggregate, uuid, initial_state: State)

      assert %State{uuid: ^uuid, name: "Test"} = state
    end

    test "should dispatch command and use state module for initial state" do
      uuid = UUID.uuid4()

      assert :ok =
               StateModuleRouter.dispatch(
                 %CreateCommand{uuid: uuid, name: "Test"},
                 @dispatch_opts
               )

      recorded_events = EventStore.stream_forward(DefaultApp, uuid, 0) |> Enum.to_list()
      assert length(recorded_events) == 1

      [event] = recorded_events
      assert %CreatedEvent{uuid: ^uuid, name: "Test"} = event.data
    end

    test "should return aggregate state with correct state module struct" do
      uuid = UUID.uuid4()

      assert {:ok, %State{uuid: ^uuid, name: "Test"}} =
               StateModuleRouter.dispatch(
                 %CreateCommand{uuid: uuid, name: "Test"},
                 Keyword.merge(@dispatch_opts, returning: :aggregate_state)
               )
    end

    test "should apply multiple events to state module struct" do
      uuid = UUID.uuid4()

      assert :ok =
               StateModuleRouter.dispatch(
                 %CreateCommand{uuid: uuid, name: "Initial"},
                 @dispatch_opts
               )

      assert {:ok, %State{uuid: ^uuid, name: "Updated"}} =
               StateModuleRouter.dispatch(
                 %UpdateCommand{uuid: uuid, name: "Updated"},
                 Keyword.merge(@dispatch_opts, returning: :aggregate_state)
               )

      recorded_events = EventStore.stream_forward(DefaultApp, uuid, 0) |> Enum.to_list()
      assert length(recorded_events) == 2
    end

    test "should return events from dispatch" do
      uuid = UUID.uuid4()

      assert {:ok, [%CreatedEvent{uuid: ^uuid, name: "Test"}]} =
               StateModuleRouter.dispatch(
                 %CreateCommand{uuid: uuid, name: "Test"},
                 Keyword.merge(@dispatch_opts, returning: :events)
               )
    end

    test "should return execution result with state module struct" do
      uuid = UUID.uuid4()

      assert {:ok, result} =
               StateModuleRouter.dispatch(
                 %CreateCommand{uuid: uuid, name: "Test"},
                 Keyword.merge(@dispatch_opts, returning: :execution_result)
               )

      assert result.aggregate_uuid == uuid
      assert result.aggregate_version == 1
      assert %State{uuid: ^uuid, name: "Test"} = result.aggregate_state
      assert [%CreatedEvent{uuid: ^uuid, name: "Test"}] = result.events
    end
  end

  describe "snapshotting with separate state module" do
    setup do
      stop_supervised!(DefaultApp)

      start_supervised!(
        {DefaultApp,
         snapshotting: %{StateModuleAggregate => [snapshot_every: 2, snapshot_version: 1]}}
      )

      :ok
    end

    test "should create snapshot with state module struct" do
      uuid = UUID.uuid4()

      ref = attach_snapshot_listener(DefaultApp, uuid)

      assert :ok =
               StateModuleRouter.dispatch(
                 %CreateCommand{uuid: uuid, name: "Initial"},
                 @dispatch_opts
               )

      assert :ok =
               StateModuleRouter.dispatch(
                 %UpdateCommand{uuid: uuid, name: "Updated"},
                 @dispatch_opts
               )

      wait_for_snapshot(ref)

      assert {:ok, snapshot} = EventStore.read_snapshot(DefaultApp, uuid)

      assert %SnapshotData{
               source_uuid: ^uuid,
               source_version: 2,
               source_type: "Elixir.Commanded.Commands.StateModuleAggregate.State",
               data: %State{uuid: ^uuid, name: "Updated"},
               metadata: %{"snapshot_module_version" => 1}
             } = snapshot
    end

    test "should restore state from snapshot after aggregate restart" do
      uuid = UUID.uuid4()

      ref = attach_snapshot_listener(DefaultApp, uuid)

      assert :ok =
               StateModuleRouter.dispatch(
                 %CreateCommand{uuid: uuid, name: "Initial"},
                 @dispatch_opts
               )

      assert :ok =
               StateModuleRouter.dispatch(
                 %UpdateCommand{uuid: uuid, name: "Snapshotted"},
                 @dispatch_opts
               )

      wait_for_snapshot(ref)

      assert {:ok, _snapshot} = EventStore.read_snapshot(DefaultApp, uuid)

      :ok = Aggregate.shutdown(DefaultApp, StateModuleAggregate, uuid)

      {:ok, ^uuid} =
        Supervisor.open_aggregate(DefaultApp, StateModuleAggregate, uuid, initial_state: State)

      state = Aggregate.aggregate_state(DefaultApp, StateModuleAggregate, uuid)
      assert %State{uuid: ^uuid, name: "Snapshotted"} = state
      assert Aggregate.aggregate_version(DefaultApp, StateModuleAggregate, uuid) == 2
    end

    test "should restore state from snapshot and apply newer events" do
      uuid = UUID.uuid4()

      ref = attach_snapshot_listener(DefaultApp, uuid)

      assert :ok =
               StateModuleRouter.dispatch(
                 %CreateCommand{uuid: uuid, name: "Initial"},
                 @dispatch_opts
               )

      assert :ok =
               StateModuleRouter.dispatch(
                 %UpdateCommand{uuid: uuid, name: "Snapshotted"},
                 @dispatch_opts
               )

      wait_for_snapshot(ref)

      assert :ok =
               StateModuleRouter.dispatch(
                 %UpdateCommand{uuid: uuid, name: "AfterSnapshot"},
                 @dispatch_opts
               )

      assert {:ok, snapshot} = EventStore.read_snapshot(DefaultApp, uuid)
      assert snapshot.source_version == 2

      :ok = Aggregate.shutdown(DefaultApp, StateModuleAggregate, uuid)

      {:ok, ^uuid} =
        Supervisor.open_aggregate(DefaultApp, StateModuleAggregate, uuid, initial_state: State)

      state = Aggregate.aggregate_state(DefaultApp, StateModuleAggregate, uuid)
      assert %State{uuid: ^uuid, name: "AfterSnapshot"} = state
      assert Aggregate.aggregate_version(DefaultApp, StateModuleAggregate, uuid) == 3
    end

    test "should use initial_state when no snapshot exists" do
      uuid = UUID.uuid4()

      assert :ok =
               StateModuleRouter.dispatch(
                 %CreateCommand{uuid: uuid, name: "Initial"},
                 @dispatch_opts
               )

      assert {:error, :snapshot_not_found} = EventStore.read_snapshot(DefaultApp, uuid)

      :ok = Aggregate.shutdown(DefaultApp, StateModuleAggregate, uuid)

      {:ok, ^uuid} =
        Supervisor.open_aggregate(DefaultApp, StateModuleAggregate, uuid, initial_state: State)

      state = Aggregate.aggregate_state(DefaultApp, StateModuleAggregate, uuid)
      assert %State{uuid: ^uuid, name: "Initial"} = state
      assert Aggregate.aggregate_version(DefaultApp, StateModuleAggregate, uuid) == 1
    end
  end

  describe "backward compatibility" do
    defmodule LegacyAggregate do
      @derive Jason.Encoder
      defstruct [:uuid, :name]

      defmodule Command do
        @derive Jason.Encoder
        defstruct [:uuid, :name]
      end

      defmodule Event do
        @derive Jason.Encoder
        defstruct [:uuid, :name]
      end

      def execute(%__MODULE__{}, %Command{uuid: uuid, name: name}) do
        %Event{uuid: uuid, name: name}
      end

      def apply(%__MODULE__{} = state, %Event{uuid: uuid, name: name}) do
        %__MODULE__{state | uuid: uuid, name: name}
      end
    end

    defmodule LegacyRouter do
      use Commanded.Commands.Router

      alias Commanded.Commands.StateModuleTest.LegacyAggregate
      alias Commanded.Commands.StateModuleTest.LegacyAggregate.Command

      dispatch Command,
        to: LegacyAggregate,
        identity: :uuid
    end

    test "should work without state option (backward compatible)" do
      uuid = UUID.uuid4()

      assert {:ok, %LegacyAggregate{uuid: ^uuid, name: "Test"}} =
               LegacyRouter.dispatch(
                 %LegacyAggregate.Command{uuid: uuid, name: "Test"},
                 Keyword.merge(@dispatch_opts, returning: :aggregate_state)
               )
    end
  end

  describe "initial_state validation" do
    defmodule InvalidStateModule do
      @derive Jason.Encoder
      defstruct [:uuid]
    end

    test "should raise when aggregate_state receives a module without initial_state/0" do
      uuid = UUID.uuid4()

      assert_raise ArgumentError,
                   "initial_state module Commanded.Commands.StateModuleTest.InvalidStateModule must export initial_state/0 function.",
                   fn ->
                     Aggregate.aggregate_state(
                       DefaultApp,
                       StateModuleAggregate,
                       uuid,
                       initial_state: InvalidStateModule
                     )
                   end
    end

    test "should reject opening a running aggregate with conflicting initial_state" do
      uuid = UUID.uuid4()

      assert :ok =
               StateModuleRouter.dispatch(
                 %CreateCommand{uuid: uuid, name: "Initial"},
                 @dispatch_opts
               )

      assert {:error,
              {:conflicting_initial_state,
               %{
                 aggregate_module: StateModuleAggregate,
                 aggregate_uuid: ^uuid,
                 requested_initial_state: nil,
                 running_initial_state: State
               }}} =
               Supervisor.open_aggregate(DefaultApp, StateModuleAggregate, uuid)
    end

    test "should return conflict error when dispatching from router with mismatched initial_state" do
      uuid = UUID.uuid4()

      Code.eval_string("""
      defmodule Commanded.Commands.StateModuleTest.RuntimeMismatchedInitialStateRouter do
        use Commanded.Commands.Router

        alias Commanded.Commands.StateModuleAggregate
        alias Commanded.Commands.StateModuleAggregate.CreateCommand

        dispatch CreateCommand,
          to: StateModuleAggregate,
          identity: :uuid
      end
      """)

      assert :ok =
               StateModuleRouter.dispatch(
                 %CreateCommand{uuid: uuid, name: "Initial"},
                 @dispatch_opts
               )

      router =
        Module.concat([
          Commanded.Commands.StateModuleTest,
          RuntimeMismatchedInitialStateRouter
        ])

      assert {:error,
              {:conflicting_initial_state,
               %{
                 aggregate_module: StateModuleAggregate,
                 aggregate_uuid: ^uuid,
                 requested_initial_state: nil,
                 running_initial_state: State
               }}} =
               router.dispatch(
                 %CreateCommand{uuid: uuid, name: "Mismatch"},
                 @dispatch_opts
               )
    end
  end
end
