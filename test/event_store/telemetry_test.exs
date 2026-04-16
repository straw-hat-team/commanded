defmodule Commanded.EventStore.TelemetryTest do
  use ExUnit.Case

  import Mox

  alias Commanded.DefaultApp
  alias Commanded.EventStore
  alias Commanded.EventStore.AdapterTestData
  alias Commanded.EventStore.Adapters.Mock, as: MockEventStore
  alias Commanded.EventStore.RecordedEvent
  alias Commanded.Middleware.Commands.IncrementCount
  alias Commanded.Middleware.Commands.RaiseError
  alias Commanded.MockedApp
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

  describe "snapshotting telemetry events" do
    test "emit `[:commanded, :event_store, :record_snapshot, :start | :stop]` event" do
      snapshot = build_snapshot()
      assert :ok = EventStore.record_snapshot(DefaultApp, snapshot)

      assert_receive {[:commanded, :event_store, :record_snapshot, :start], 1, _meas, _meta}
      assert_receive {[:commanded, :event_store, :record_snapshot, :stop], 2, _meas, meta}
      assert %{application: DefaultApp, snapshot: ^snapshot} = meta
    end

    test "emit `[:commanded, :event_store, :read_snapshot, :start | :stop]` event" do
      uuid = UUID.uuid4()
      assert {:error, :snapshot_not_found} = EventStore.read_snapshot(DefaultApp, uuid)

      assert_receive {[:commanded, :event_store, :read_snapshot, :start], 1, _meas, _meta}
      assert_receive {[:commanded, :event_store, :read_snapshot, :stop], 2, _meas, meta}
      assert %{application: DefaultApp, source_uuid: ^uuid} = meta
    end

    test "emit `[:commanded, :event_store, :delete_snapshot, :start | :stop]` event" do
      uuid = UUID.uuid4()
      assert :ok = EventStore.delete_snapshot(DefaultApp, uuid)

      assert_receive {[:commanded, :event_store, :delete_snapshot, :start], 1, _meas, _meta}
      assert_receive {[:commanded, :event_store, :delete_snapshot, :stop], 2, _meas, meta}
      assert %{application: DefaultApp, source_uuid: ^uuid} = meta
    end
  end

  describe "streaming telemetry events" do
    test "emit `[:commanded, :event_store, :stream_forward, :start | :stop]` event" do
      uuid = UUID.uuid4()
      assert {:error, :stream_not_found} = EventStore.stream_forward(DefaultApp, uuid)

      assert_receive {[:commanded, :event_store, :stream_forward, :start], 1, _meas, _meta}
      assert_receive {[:commanded, :event_store, :stream_forward, :stop], 2, _meas, meta}

      assert %{
               application: DefaultApp,
               stream_uuid: ^uuid,
               start_version: 0,
               read_batch_size: 1_000
             } = meta
    end

    test "emit stream_forward start/stop when adapter returns a list (before caller enumerates)" do
      uuid = UUID.uuid4()
      assert :ok = EventStore.append_to_stream(DefaultApp, uuid, 0, build_events(1))

      assert_receive {[:commanded, :event_store, :append_to_stream, :start], 1, _meas, _meta}
      assert_receive {[:commanded, :event_store, :append_to_stream, :stop], 2, _meas, _meta}

      stream = EventStore.stream_forward(DefaultApp, uuid, 0)

      assert_receive {[:commanded, :event_store, :stream_forward, :start], 3, _meas, _meta}
      assert_receive {[:commanded, :event_store, :stream_forward, :stop], 4, _meas, meta}

      assert %{
               application: DefaultApp,
               stream_uuid: ^uuid,
               start_version: 0,
               read_batch_size: 1_000
             } = meta

      assert is_list(stream)
      assert length(stream) == 1
    end

    test "deferred :stop fires only after lazy stream is enumerated" do
      {_app, _handler} = start_mocked_lazy_stream([:a, :b])

      stream = EventStore.stream_forward(Commanded.MockedApp, "stream-uuid", 0)

      assert_receive {:deferred, [:commanded, :event_store, :stream_forward, :start], _start_meas,
                      %{telemetry_span_context: ctx}}

      refute_receive {:deferred, [:commanded, :event_store, :stream_forward, :stop], _, _}, 50

      assert [:a, :b] = Enum.to_list(stream)

      assert_receive {:deferred, [:commanded, :event_store, :stream_forward, :stop], stop_meas,
                      stop_meta}

      assert stop_meta.telemetry_span_context == ctx
      assert is_integer(stop_meas.duration)
      assert stop_meas.duration >= 0
    end

    test "deferred :stop fires when lazy stream is halted early" do
      {_app, _handler} = start_mocked_lazy_stream([:a, :b, :c])

      stream = EventStore.stream_forward(Commanded.MockedApp, "stream-uuid", 0)

      assert_receive {:deferred, [:commanded, :event_store, :stream_forward, :start], _, _}
      refute_receive {:deferred, [:commanded, :event_store, :stream_forward, :stop], _, _}, 50

      assert [:a] = Enum.take(stream, 1)

      assert_receive {:deferred, [:commanded, :event_store, :stream_forward, :stop], stop_meas, _}
      assert is_integer(stop_meas.duration)
    end

    test "emit stream_forward :exception after :start when application lookup raises" do
      missing = :stream_forward_telemetry_missing_commanded_app_xx
      handler = :"stream_forward_ex-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [
          [:commanded, :event_store, :stream_forward, :start],
          [:commanded, :event_store, :stream_forward, :exception]
        ],
        fn event, measurements, metadata, reply_to ->
          send(reply_to, {:stream_forward_telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert_raise RuntimeError, fn ->
        EventStore.stream_forward(missing, "stream-uuid", 0)
      end

      assert_receive {:stream_forward_telemetry,
                      [:commanded, :event_store, :stream_forward, :start], _start_meas,
                      start_meta}

      assert_receive {:stream_forward_telemetry,
                      [:commanded, :event_store, :stream_forward, :exception], ex_meas, ex_meta}

      assert start_meta.telemetry_span_context == ex_meta.telemetry_span_context
      assert ex_meta.kind == :error
      assert %RuntimeError{} = ex_meta.reason
      assert is_list(ex_meta.stacktrace)
      assert is_integer(ex_meas.duration)
    end
  end

  describe "ack_event telemetry events" do
    test "emit `[:commanded, :event_store, :ack_event, :start | :stop]` event" do
      pid = self()
      event = %RecordedEvent{}
      assert :ok = EventStore.ack_event(DefaultApp, pid, event)

      assert_receive {[:commanded, :event_store, :ack_event, :start], 1, _meas, _meta}
      assert_receive {[:commanded, :event_store, :ack_event, :stop], 2, _meas, meta}
      assert %{application: DefaultApp, subscription: ^pid, event: ^event} = meta
    end
  end

  describe "append_to_stream telemetry events" do
    test "emit `[:commanded, :event_store, :append_to_stream, :start | :stop]` event" do
      uuid = UUID.uuid4()
      assert :ok = EventStore.append_to_stream(DefaultApp, uuid, 0, build_events(1))

      assert_receive {[:commanded, :event_store, :append_to_stream, :start], 1, _meas, _meta}
      assert_receive {[:commanded, :event_store, :append_to_stream, :stop], 2, _meas, meta}
      assert %{application: DefaultApp, expected_version: 0, stream_uuid: ^uuid} = meta
    end
  end

  describe "subscription telemetry events" do
    test "emit `[:commanded, :event_store, :subscribe, :start | :stop]` event" do
      uuid = UUID.uuid4()
      assert :ok = EventStore.subscribe(DefaultApp, uuid)

      assert_receive {[:commanded, :event_store, :subscribe, :start], 1, _meas, _meta}
      assert_receive {[:commanded, :event_store, :subscribe, :stop], 2, _meas, meta}
      assert %{application: DefaultApp, stream_uuid: ^uuid} = meta
    end

    test "emit `[:commanded, :event_store, :subscribe_to, :start | :stop]` event" do
      subscriber = self()
      assert {:ok, pid} = EventStore.subscribe_to(DefaultApp, :all, "Test", subscriber, :current)

      assert_receive {:subscribed, ^pid}
      assert_receive {[:commanded, :event_store, :subscribe_to, :start], 1, _meas, _meta}
      assert_receive {[:commanded, :event_store, :subscribe_to, :stop], 2, _meas, meta}

      assert %{
               application: DefaultApp,
               stream_uuid: :all,
               subscription_name: "Test",
               subscriber: ^subscriber,
               start_from: :current
             } = meta
    end

    test "emit `[:commanded, :event_store, :unsubscribe, :start | :stop]` event" do
      assert {:ok, pid} = EventStore.subscribe_to(DefaultApp, :all, "Test", self(), :current)

      assert_receive {:subscribed, ^pid}

      assert_receive {[:commanded, :event_store, :subscribe_to, :start], 1, _meas, _meta}
      assert_receive {[:commanded, :event_store, :subscribe_to, :stop], 2, _meas, _meta}

      assert :ok = EventStore.unsubscribe(DefaultApp, pid)

      assert_receive {[:commanded, :event_store, :unsubscribe, :start], 3, _meas, _meta}
      assert_receive {[:commanded, :event_store, :unsubscribe, :stop], 4, _meas, meta}
      assert %{application: DefaultApp, subscription: ^pid} = meta
    end

    test "emit `[:commanded, :event_store, :delete_subscription, :start | :stop]` event" do
      assert {:error, :subscription_not_found} =
               EventStore.delete_subscription(DefaultApp, :all, "Test")

      assert_receive {[:commanded, :event_store, :delete_subscription, :start], 1, _meas, _meta}
      assert_receive {[:commanded, :event_store, :delete_subscription, :stop], 2, _meas, meta}
      assert %{application: DefaultApp, subscribe_to: :all, handler_name: "Test"} = meta
    end
  end

  defp start_mocked_lazy_stream(elements) do
    set_mox_global()

    stub(MockEventStore, :child_spec, fn _app, _cfg -> {:ok, [], %{}} end)
    stub(MockEventStore, :subscribe, fn _meta, _stream -> :ok end)

    stub(MockEventStore, :stream_forward, fn _meta, _uuid, _from, _batch ->
      Stream.map(elements, & &1)
    end)

    start_supervised!(MockedApp)

    handler = :"deferred-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:commanded, :event_store, :stream_forward, :start],
        [:commanded, :event_store, :stream_forward, :stop]
      ],
      fn event, measurements, metadata, reply_to ->
        send(reply_to, {:deferred, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {MockedApp, handler}
  end

  defp attach_telemetry do
    agent = start_supervised!({Agent, fn -> 1 end})
    handler = :"#{__MODULE__}-handler"

    events = [
      :ack_event,
      :append_to_stream,
      :delete_snapshot,
      :delete_subscription,
      :record_snapshot,
      :read_snapshot,
      :stream_forward,
      :subscribe,
      :subscribe_to,
      :unsubscribe
    ]

    :telemetry.attach_many(
      handler,
      Enum.flat_map(events, fn event ->
        [
          [:commanded, :event_store, event, :start],
          [:commanded, :event_store, event, :stop],
          [:commanded, :event_store, event, :exception]
        ]
      end),
      fn event_name, measurements, metadata, reply_to ->
        num = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
        send(reply_to, {event_name, num, measurements, metadata})
      end,
      self()
    )

    on_exit(fn ->
      :telemetry.detach(handler)
    end)
  end

  defp build_events(count), do: AdapterTestData.build_opened_events(count)

  defp build_snapshot(source_uuid \\ UUID.uuid4()) do
    AdapterTestData.build_snapshot_data(5, source_uuid: source_uuid)
  end
end
