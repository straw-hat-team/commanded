defmodule Commanded.Event.HandlerInitTest do
  use Commanded.MockEventStoreCase

  alias Commanded.DefaultApp
  alias Commanded.Event.{EchoHandler, Handler, ReplyEvent, RuntimeConfigHandler}
  alias Commanded.Helpers.{EventFactory, Wait}

  describe "event handler `init/1` callback" do
    setup do
      for tenant <- [:tenant1, :tenant2, :tenant3] do
        start_supervised!({DefaultApp, name: Module.concat([DefaultApp, tenant])})
      end

      :ok
    end

    test "should be called at runtime" do
      {:ok, handler1} = RuntimeConfigHandler.start_link(tenant: :tenant1, reply_to: self())
      {:ok, handler2} = RuntimeConfigHandler.start_link(tenant: :tenant2, reply_to: self())
      {:ok, handler3} = RuntimeConfigHandler.start_link(tenant: :tenant3, reply_to: self())

      assert_receive {:init, :tenant1}
      assert_receive {:init, :tenant2}
      assert_receive {:init, :tenant3}

      assert_handler_application(handler1, Module.concat([DefaultApp, :tenant1]))
      assert_handler_application(handler2, Module.concat([DefaultApp, :tenant2]))
      assert_handler_application(handler3, Module.concat([DefaultApp, :tenant3]))

      assert_handler_name(handler1, "Commanded.Event.RuntimeConfigHandler.tenant1")
      assert_handler_name(handler2, "Commanded.Event.RuntimeConfigHandler.tenant2")
      assert_handler_name(handler3, "Commanded.Event.RuntimeConfigHandler.tenant3")
    end

    test "should be called on restart if the process crashes" do
      handler = start_supervised!({RuntimeConfigHandler, tenant: :tenant1, reply_to: self()})

      Process.exit(handler, :kill)

      assert_receive {:init, :tenant1}
      assert_receive {:init, :tenant1}
      refute_receive {:init, :tenant1}
    end
  end

  describe "event handler start options" do
    test "should be passed when starting handler via `start_link/1`" do
      {:ok, handler} = EchoHandler.start_link(hibernate_after: 1)

      Wait.until(fn -> assert_hibernated(handler) end)
    end

    test "should be passed when starting handler via child spec" do
      handler = start_supervised!({EchoHandler, hibernate_after: 1})

      Wait.until(fn -> assert_hibernated(handler) end)
    end

    test "hibernated handler should resume after receiving event message" do
      handler = start_supervised!({EchoHandler, hibernate_after: 1})

      # Handler should hibernate
      Wait.until(fn -> assert_hibernated(handler) end)

      reply_to = :erlang.pid_to_list(self())
      event = %ReplyEvent{reply_to: reply_to, value: 1}

      # Sending a message should wake the handler
      send_events(handler, [event])

      assert_receive {:event, ^handler, ^event, _metadata}

      # Handler should hibernate again
      Wait.until(fn -> assert_hibernated(handler) end)
    end
  end

  defp assert_handler_application(handler, expected_application) do
    %Handler{application: application} = :sys.get_state(handler)

    assert application == expected_application
  end

  defp assert_handler_name(handler, expected_handler_name) do
    %Handler{handler_name: handler_name} = :sys.get_state(handler)

    assert handler_name == expected_handler_name
  end

  defp assert_hibernated(pid) do
    pre_otp_28 = {:current_function, {:erlang, :hibernate, 3}}
    post_otp_28 = {:current_function, {:gen_server, :loop_hibernate, 4}}

    assert Process.info(pid, :current_function) in [pre_otp_28, post_otp_28]
  end

  defp send_events(handler, events) do
    recorded_events = EventFactory.map_to_recorded_events(events)

    send(handler, {:events, recorded_events})
  end
end
