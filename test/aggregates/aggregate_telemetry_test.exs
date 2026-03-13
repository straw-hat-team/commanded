defmodule Commanded.Aggregates.AggregateTelemetryTest do
  use Commanded.MockEventStoreCase

  alias Commanded.Aggregates.{Aggregate, ExecutionContext}
  alias Commanded.{DefaultApp, MockedApp, UUID}

  defmodule Commands do
    defmodule Ok do
      defstruct [:message]
    end

    defmodule Error do
      defstruct [:message]
    end

    defmodule RaiseException do
      defstruct [:message]
    end
  end

  defmodule Event do
    @derive Jason.Encoder
    defstruct [:message]
  end

  defmodule ExampleAggregate do
    alias Commands.{Error, Ok, RaiseException}

    defstruct [:message]

    def execute(%ExampleAggregate{}, %Ok{message: message}), do: %Event{message: message}
    def execute(%ExampleAggregate{}, %Error{message: message}), do: {:error, message}
    def execute(%ExampleAggregate{}, %RaiseException{message: message}), do: raise(message)

    def apply(%ExampleAggregate{}, %Event{message: message}),
      do: %ExampleAggregate{message: message}
  end

  alias Commands.{Error, Ok, RaiseException}

  setup do
    start_supervised!(DefaultApp)
    attach_telemetry()
    :ok
  end

  describe "aggregate telemetry" do
    setup do
      aggregate_uuid = UUID.uuid4()

      {:ok, pid} = start_aggregate(aggregate_uuid)

      [aggregate_uuid: aggregate_uuid, pid: pid]
    end

    test "emit `[:commanded, :aggregate, :execute, :start]` event",
         %{aggregate_uuid: aggregate_uuid, pid: pid} do
      context = %ExecutionContext{
        command: %Ok{message: "ok"},
        function: :execute,
        handler: ExampleAggregate
      }

      self = self()

      {:ok, 1, _events, _aggregate_state} = GenServer.call(pid, {:execute_command, context})

      assert_receive {[:commanded, :aggregate, :execute, :start], measurements, metadata}

      assert match?(%{system_time: _system_time}, measurements)
      assert is_number(measurements.system_time)

      assert match?(
               %{
                 aggregate_state: %ExampleAggregate{},
                 aggregate_uuid: ^aggregate_uuid,
                 aggregate_version: 0,
                 application: Commanded.DefaultApp,
                 caller: ^self,
                 execution_context: ^context
               },
               metadata
             )

      assert_receive {[:commanded, :aggregate, :execute, :stop], _measurements, _metadata}
      refute_received {[:commanded, :aggregate, :execute, :exception], _measurements, _metadata}
    end

    test "emit `[:commanded, :aggregate, :execute, :stop]` event",
         %{aggregate_uuid: aggregate_uuid, pid: pid} do
      context = %ExecutionContext{
        command: %Ok{message: "ok"},
        function: :execute,
        handler: ExampleAggregate
      }

      self = self()

      {:ok, 1, events, _aggregate_state} = GenServer.call(pid, {:execute_command, context})

      assert_receive {[:commanded, :aggregate, :execute, :start], _measurements, _metadata}
      assert_receive {[:commanded, :aggregate, :execute, :stop], measurements, metadata}

      assert match?(%{duration: _duration}, measurements)
      assert is_number(measurements.duration)

      assert match?(
               %{
                 aggregate_state: %ExampleAggregate{message: "ok"},
                 aggregate_uuid: ^aggregate_uuid,
                 aggregate_version: 1,
                 application: Commanded.DefaultApp,
                 caller: ^self,
                 execution_context: ^context,
                 events: ^events
               },
               metadata
             )

      refute_received {[:commanded, :aggregate, :execute, :exception], _measurements, _metadata}
    end

    test "emit `[:commanded, :aggregate, :execute, :stop]` with error event",
         %{aggregate_uuid: aggregate_uuid, pid: pid} do
      context = %ExecutionContext{
        command: %Error{message: "an error"},
        function: :execute,
        handler: ExampleAggregate
      }

      self = self()

      {:error, "an error"} = GenServer.call(pid, {:execute_command, context})

      assert_receive {[:commanded, :aggregate, :execute, :start], _measurements, _metadata}
      assert_receive {[:commanded, :aggregate, :execute, :stop], measurements, metadata}

      assert match?(%{duration: _duration}, measurements)
      assert is_number(measurements.duration)

      assert match?(
               %{
                 aggregate_state: %ExampleAggregate{},
                 aggregate_uuid: ^aggregate_uuid,
                 aggregate_version: 0,
                 application: Commanded.DefaultApp,
                 caller: ^self,
                 execution_context: ^context,
                 error: "an error"
               },
               metadata
             )

      refute_received {[:commanded, :aggregate, :execute, :exception], _measurements, _metadata}
    end

    test "emit `[:commanded, :aggregate, :execute, :exception]` event",
         %{aggregate_uuid: aggregate_uuid, pid: pid} do
      context = %ExecutionContext{
        command: %RaiseException{message: "an exception"},
        function: :execute,
        handler: ExampleAggregate
      }

      self = self()

      Process.unlink(pid)

      {:error, %RuntimeError{message: "an exception"}} =
        GenServer.call(pid, {:execute_command, context})

      assert_receive {[:commanded, :aggregate, :execute, :start], _measurements, _metadata}
      assert_receive {[:commanded, :aggregate, :execute, :exception], measurements, metadata}

      assert match?(%{duration: _duration}, measurements)
      assert is_number(measurements.duration)

      assert match?(
               %{
                 aggregate_state: %ExampleAggregate{},
                 aggregate_uuid: ^aggregate_uuid,
                 aggregate_version: 0,
                 application: Commanded.DefaultApp,
                 caller: ^self,
                 execution_context: ^context,
                 kind: :error,
                 reason: %RuntimeError{message: "an exception"},
                 stacktrace: _stacktrace
               },
               metadata
             )

      refute_received {[:commanded, :aggregate, :execute, :stop], _measurements, _metadata}
    end

    test "emit `[:commanded, :aggregate, :load]` events for new aggregate (stream_not_found)",
         %{aggregate_uuid: aggregate_uuid} do
      # Setup already started the aggregate. For a new aggregate, stream_forward returns
      # {:error, :stream_not_found}. Load telemetry fires with count: 0; populate does not fire.
      assert_receive {[:commanded, :aggregate, :load, :start], _measurements, _metadata}
      assert_receive {[:commanded, :aggregate, :load, :stop], measurements, metadata}

      assert match?(%{count: 0}, measurements)

      assert match?(
               %{
                 aggregate_state: %ExampleAggregate{},
                 aggregate_uuid: ^aggregate_uuid,
                 aggregate_version: 0,
                 application: DefaultApp
               },
               metadata
             )

      refute_received {[:commanded, :aggregate, :populate, :start], _, _}
      refute_received {[:commanded, :aggregate, :populate, :stop], _, _}
    end

    test "emit `[:commanded, :aggregate, :load]` and `[:commanded, :aggregate, :populate]` for existing aggregate (reload)",
         %{aggregate_uuid: aggregate_uuid, pid: pid} do
      context = %ExecutionContext{
        command: %Ok{message: "ok"},
        function: :execute,
        handler: ExampleAggregate
      }

      # Send some commands, then kill the process to force a reload.
      count = 3

      for _i <- 1..count do
        {:ok, _version, _events, _aggregate} = GenServer.call(pid, {:execute_command, context})
      end

      Process.exit(pid, :normal)

      # Do the reload. Consume initial load (count: 0) from setup, then reload load + populate.
      assert_receive {[:commanded, :aggregate, :load, :start], _, _}
      assert_receive {[:commanded, :aggregate, :load, :stop], %{count: 0}, _}

      start_aggregate(aggregate_uuid)

      assert_receive {[:commanded, :aggregate, :load, :start], _, _}
      assert_receive {[:commanded, :aggregate, :populate, :start], _, _}
      assert_receive {[:commanded, :aggregate, :populate, :stop], %{count: ^count}, metadata}
      assert_receive {[:commanded, :aggregate, :load, :stop], %{count: ^count}, _}

      assert match?(
               %{
                 aggregate_state: %ExampleAggregate{},
                 aggregate_uuid: ^aggregate_uuid,
                 aggregate_version: ^count,
                 application: DefaultApp
               },
               metadata
             )
    end

    test "emit `[:commanded, :aggregate, :execute, :wrong_expected_version]` event" do
      aggregate_uuid = UUID.uuid4()

      expect(MockEventStore, :subscribe, fn _event_store_meta, aggregate_uuid ->
        assert is_binary(aggregate_uuid)
        :ok
      end)

      expect(MockEventStore, :append_to_stream, fn _meta,
                                                   ^aggregate_uuid,
                                                   _exp_ver,
                                                   _event_data,
                                                   _opts ->
        {:error, :wrong_expected_version}
      end)

      expect(MockEventStore, :stream_forward, 2, fn _meta, ^aggregate_uuid, _from, _batch_size ->
        []
      end)

      assert {:ok, _pid} = start_aggregate(aggregate_uuid, application: Commanded.MockedApp)

      assert {:error, :too_many_attempts} =
               Aggregate.execute(
                 Commanded.MockedApp,
                 ExampleAggregate,
                 aggregate_uuid,
                 %ExecutionContext{
                   command: %Ok{message: "ok"},
                   function: :execute,
                   handler: ExampleAggregate,
                   retry_attempts: 0
                 }
               )

      assert_receive {[:commanded, :aggregate, :execute, :wrong_expected_version], measurements,
                      metadata}

      assert measurements == %{count: 1}
      assert metadata.application == Commanded.MockedApp
      assert metadata.aggregate_uuid == aggregate_uuid
      assert metadata.aggregate_version == 0
      assert metadata.aggregate_state == %ExampleAggregate{message: nil}
      assert metadata.caller == self()
      assert metadata.execution_context.command == %Ok{message: "ok"}
      assert metadata.execution_context.retry_attempts == 0
    end
  end

  @tag :unit
  describe "load/populate telemetry (unit: MockedApp + expect)" do
    setup do
      attach_telemetry()
      :ok
    end

    test "load only when stream_forward returns stream_not_found" do
      aggregate_uuid = UUID.uuid4()

      expect(MockEventStore, :subscribe, fn _meta, ^aggregate_uuid -> :ok end)

      expect(MockEventStore, :stream_forward, fn _meta, ^aggregate_uuid, _from, _batch_size ->
        {:error, :stream_not_found}
      end)

      assert {:ok, _pid} = start_aggregate(aggregate_uuid, application: MockedApp)

      assert_receive {[:commanded, :aggregate, :load, :start], _, _}
      assert_receive {[:commanded, :aggregate, :load, :stop], %{count: 0}, _}

      refute_received {[:commanded, :aggregate, :populate, :start], _, _}
      refute_received {[:commanded, :aggregate, :populate, :stop], _, _}
    end

    test "load + populate when stream_forward returns events" do
      aggregate_uuid = UUID.uuid4()
      count = 2

      expect(MockEventStore, :subscribe, fn _meta, ^aggregate_uuid -> :ok end)

      expect(MockEventStore, :stream_forward, fn _meta, ^aggregate_uuid, _from, _batch_size ->
        for i <- 1..count do
          %Commanded.EventStore.RecordedEvent{
            event_id: UUID.uuid4(),
            event_number: i,
            stream_id: aggregate_uuid,
            stream_version: i,
            correlation_id: nil,
            causation_id: nil,
            event_type: "Elixir.Commanded.Aggregates.AggregateTelemetryTest.Event",
            data: %Event{message: "event#{i}"},
            metadata: nil,
            created_at: DateTime.utc_now()
          }
        end
      end)

      assert {:ok, _pid} = start_aggregate(aggregate_uuid, application: MockedApp)

      assert_receive {[:commanded, :aggregate, :load, :start], _, _}
      assert_receive {[:commanded, :aggregate, :populate, :start], _, _}
      assert_receive {[:commanded, :aggregate, :populate, :stop], %{count: ^count}, _}
      assert_receive {[:commanded, :aggregate, :load, :stop], %{count: ^count}, _}
    end
  end

  def start_aggregate(aggregate_uuid) do
    Aggregate.start_link([application: DefaultApp],
      aggregate_module: ExampleAggregate,
      aggregate_uuid: aggregate_uuid
    )
  end

  def start_aggregate(aggregate_uuid, opts) do
    aggregate = ExampleAggregate
    app = Keyword.fetch!(opts, :application)
    name = Aggregate.name(app, aggregate, aggregate_uuid)

    Aggregate.start_link([application: app],
      aggregate_module: aggregate,
      aggregate_uuid: aggregate_uuid,
      name: Commanded.Registration.via_tuple(app, name)
    )
  end

  defp attach_telemetry do
    :telemetry.attach_many(
      "test-handler",
      [
        [:commanded, :aggregate, :execute, :start],
        [:commanded, :aggregate, :execute, :stop],
        [:commanded, :aggregate, :execute, :exception],
        [:commanded, :aggregate, :execute, :wrong_expected_version],
        [:commanded, :aggregate, :load, :start],
        [:commanded, :aggregate, :load, :stop],
        [:commanded, :aggregate, :populate, :start],
        [:commanded, :aggregate, :populate, :stop]
      ],
      &__MODULE__.send_self(&1, &2, &3, &4),
      self()
    )

    on_exit(fn ->
      :telemetry.detach("test-handler")
    end)
  end

  def send_self(event_name, measurements, metadata, reply_to) do
    send(reply_to, {event_name, measurements, metadata})
  end
end
