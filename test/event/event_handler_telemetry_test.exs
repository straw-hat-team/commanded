defmodule Commanded.Event.EventHandlerTelemetryTest do
  use ExUnit.Case

  alias Commanded.Application.Config
  alias Commanded.Event.Handler
  alias Commanded.EventStore.Subscription

  alias Commanded.Helpers.EventFactory
  alias Commanded.Event.{BatchHandler, EchoHandler, ErrorHandlingBatchHandler}
  alias Commanded.Event.EventHandlerTelemetryTest.MockAdapter
  alias Commanded.Event.ReplyEvent

  setup do
    attach_telemetry()
    :ok
  end

  describe "single-event handler" do
    test "emits :start and :stop" do
      recorded_events = EventFactory.map_to_recorded_events([reply_event(1)])
      state = setup_state(EchoHandler, :event)

      Handler.handle_info({:events, recorded_events}, state)

      assert_receive {[:commanded, :event, :handle, :start], _measurements, _metadata}
      assert_receive {[:commanded, :event, :handle, :stop], _measurements, _metadata}
      refute_received {[:commanded, :event, :handle, :exception], _measurements, _metadata}
    end

    test "includes processing_latency_ms in :stop measurements" do
      recorded_events = EventFactory.map_to_recorded_events([reply_event(1)])
      state = setup_state(EchoHandler, :event)

      Handler.handle_info({:events, recorded_events}, state)

      assert_receive {[:commanded, :event, :handle, :stop], measurements, _metadata}
      assert is_integer(measurements.processing_latency_ms)
      assert measurements.processing_latency_ms >= 0
    end
  end

  describe "batch event handler" do
    test "emits :start and :stop from :ok" do
      recorded_events =
        EventFactory.map_to_recorded_events([batch_reply_event(1), batch_reply_event(2)], 1)

      state = setup_state(BatchHandler, :batch)

      {:noreply, _state} = Handler.handle_info({:events, recorded_events}, state)

      assert_receive {[:commanded, :event, :batch, :start], _measurements, _metadata}
      assert_receive {[:commanded, :event, :batch, :stop], _measurements, metadata}
      assert metadata.event_count == 2
      refute_received {[:commanded, :event, :batch, :exception], _measurements, _metadata}
    end

    test "includes processing_latency_ms in :stop measurements" do
      recorded_events =
        EventFactory.map_to_recorded_events([batch_reply_event(1), batch_reply_event(2)], 1)

      state = setup_state(BatchHandler, :batch)

      {:noreply, _state} = Handler.handle_info({:events, recorded_events}, state)

      assert_receive {[:commanded, :event, :batch, :stop], measurements, _metadata}
      assert is_integer(measurements.processing_latency_ms)
      assert measurements.processing_latency_ms >= 0
    end

    test "emits :stop from :error" do
      recorded_events =
        EventFactory.map_to_recorded_events(
          [batch_reply_event(:error), batch_reply_event(:error)],
          1
        )

      state = setup_state(BatchHandler, :batch)

      {:stop, :bad_value, _state} = Handler.handle_info({:events, recorded_events}, state)

      assert_receive {[:commanded, :event, :batch, :start], _measurements, _metadata}
      assert_receive {[:commanded, :event, :batch, :stop], _measurements, _metadata}
      refute_received {[:commanded, :event, :batch, :exception], _measurements, _metadata}
    end

    test "emits :exception from raised exception" do
      recorded_events =
        EventFactory.map_to_recorded_events(
          [batch_reply_event(:raise), batch_reply_event(:raise)],
          1
        )

      state = setup_state(ErrorHandlingBatchHandler, :batch)

      {:stop, _, _} = Handler.handle_info({:events, recorded_events}, state)

      assert_receive {[:commanded, :event, :batch, :start], _measurements, _metadata}
      refute_received {[:commanded, :event, :batch, :stop], _measurements, _metadata}
      assert_receive {[:commanded, :event, :batch, :exception], _measurements, _metadata}
    end

    test "includes event_count in metadata when erroring on a specific event" do
      recorded_events =
        EventFactory.map_to_recorded_events(
          [
            batch_reply_event(1),
            batch_reply_event(2),
            batch_reply_event(:error),
            batch_reply_event(4)
          ],
          1
        )

      state = setup_state(BatchHandler, :batch)

      Handler.handle_info({:events, recorded_events}, state)

      assert_receive {[:commanded, :event, :batch, :start], _measurements, metadata}
      assert metadata.event_count == 4

      assert_receive {[:commanded, :event, :batch, :stop], _measurements, metadata}
      assert metadata.event_count == 4
    end
  end

  # EchoHandler expects reply_to as a charlist (:erlang.list_to_pid/1 is called internally)
  defp reply_event(value), do: %ReplyEvent{reply_to: :erlang.pid_to_list(self()), value: value}

  # BatchHandler uses reply_to directly as a pid
  defp batch_reply_event(value), do: %ReplyEvent{reply_to: self(), value: value}

  defp setup_state(handler_module, callback) do
    Config.associate(self(), __MODULE__, event_store: {MockAdapter, nil})

    %Handler{
      subscription:
        struct(Subscription,
          application: __MODULE__,
          subscription_pid: self()
        ),
      handler_callback: callback,
      handler_module: handler_module,
      application: __MODULE__,
      consistency: :eventual,
      last_seen_event: 0
    }
  end

  defp attach_telemetry do
    :telemetry.attach_many(
      "test-handler",
      [
        [:commanded, :event, :handle, :start],
        [:commanded, :event, :handle, :stop],
        [:commanded, :event, :handle, :exception],
        [:commanded, :event, :batch, :start],
        [:commanded, :event, :batch, :stop],
        [:commanded, :event, :batch, :exception]
      ],
      fn event_name, measurements, metadata, reply_to ->
        send(reply_to, {event_name, measurements, metadata})
      end,
      self()
    )

    on_exit(fn ->
      :telemetry.detach("test-handler")
    end)
  end

  defmodule MockAdapter do
    def ack_event(nil, subscription_pid, event) do
      send(subscription_pid, {:acked, event})
      :ok
    end
  end
end
