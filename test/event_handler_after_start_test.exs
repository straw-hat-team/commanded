defmodule Commanded.Event.HandlerAfterStartTest do
  use Commanded.MockEventStoreCase

  import Mox

  alias Commanded.EventStore.Adapters.Mock, as: MockEventStore

  setup do
    stub(MockEventStore, :subscribe_to, fn
      _event_store, :all, _handler_name, handler, _subscribe_from, _opts ->
        {:ok, handler}
    end)

    :ok
  end

  describe "event handler `after_start/1` callback" do
    defmodule AfterStartHandler do
      use Commanded.Event.Handler,
        application: Commanded.MockedApp,
        name: __MODULE__

      def after_start(state) do
        test_pid = Map.fetch!(state, :test)
        ref = Map.get_lazy(state, :ref, &make_ref/0)
        reply = Map.get(state, :reply, :ok)

        Process.send(test_pid, {ref, :after_start, reply}, [])
        reply
      end
    end

    test "should be called after handler subscribed" do
      ref = make_ref()
      state = %{test: self(), ref: ref}
      handler = start_supervised!({AfterStartHandler, state: state})

      refute_receive {^ref, :after_start, :ok}

      send_subscribed(handler)

      assert_receive {^ref, :after_start, :ok}
    end

    test "should reply with new state" do
      ref = make_ref()
      state = %{test: self(), ref: ref, reply: {:ok, %{something: :new}}}
      handler = start_supervised!({AfterStartHandler, state: state})

      send_subscribed(handler)

      assert_receive {^ref, :after_start, {:ok, new_state}}
      assert new_state == %{something: :new}
    end
  end

  defp send_subscribed(handler) do
    send(handler, {:subscribed, handler})
  end
end
