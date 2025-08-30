defmodule Commanded.Event.BatchResetEventHandlerTest do
  use ExUnit.Case

  import Commanded.Assertions.EventAssertions

  alias Commanded.Event.Mapper
  alias Commanded.EventStore
  alias Commanded.ExampleDomain.BankAccount.BankAccountBatchHandler
  alias Commanded.ExampleDomain.BankAccount.Events.BankAccountOpened
  alias Commanded.ExampleDomain.BankApp
  alias Commanded.Helpers.Wait
  alias Commanded.UUID

  describe "reset batch event handler" do
    setup do
      start_supervised!(BankApp)
      :ok
    end

    test "should be reset when starting from `:origin`" do
      stream_uuid = UUID.uuid4()
      initial_events = [%BankAccountOpened{account_number: "ACC123", initial_balance: 1_000}]

      :ok = EventStore.append_to_stream(BankApp, stream_uuid, 0, to_event_data(initial_events))

      handler = start_supervised!(BankAccountBatchHandler)

      Wait.until(fn ->
        assert BankAccountBatchHandler.current_accounts() == ["ACC123"]
      end)

      :ok = BankAccountBatchHandler.change_prefix("PREF_")

      send(handler, :reset)

      Wait.until(fn ->
        assert BankAccountBatchHandler.current_accounts() == ["PREF_ACC123"]
      end)
    end

    test "should be reset when starting from `:current`" do
      stream_uuid = UUID.uuid4()

      # Ignored initial events - add these BEFORE starting the handler
      initial_events = [%BankAccountOpened{account_number: "ACC123", initial_balance: 1_000}]
      :ok = EventStore.append_to_stream(BankApp, stream_uuid, 0, to_event_data(initial_events))

      # Start handler with :current - should ignore existing events
      handler = start_supervised!({BankAccountBatchHandler, start_from: :current})

      Wait.until(fn ->
        assert BankAccountBatchHandler.current_accounts() == []
      end)

      :ok = BankAccountBatchHandler.change_prefix("PREF_")

      # Use a more robust reset approach with proper synchronization
      ref = Process.monitor(handler)
      send(handler, :reset)

      # Wait for the reset message to be processed
      receive do
        {:DOWN, ^ref, :process, ^handler, _reason} ->
          # Handler died, this shouldn't happen
          flunk("Handler died during reset")
      after
        # Reset message should be processed by now
        100 -> :ok
      end

      Process.demonitor(ref)

      # Ensure reset completed and accounts are cleared
      Wait.until(fn ->
        assert BankAccountBatchHandler.current_accounts() == []
      end)

      # Add new event after reset
      new_event = [%BankAccountOpened{account_number: "ACC1234", initial_balance: 1_000}]
      :ok = EventStore.append_to_stream(BankApp, stream_uuid, 1, to_event_data(new_event))

      wait_for_event(BankApp, BankAccountOpened, fn event, recorded_event ->
        event.account_number == "ACC1234" and recorded_event.event_number == 2
      end)

      Wait.until(fn ->
        assert BankAccountBatchHandler.current_accounts() == ["PREF_ACC1234"]
      end)
    end
  end

  defp to_event_data(events) do
    Mapper.map_to_event_data(events,
      causation_id: UUID.uuid4(),
      correlation_id: UUID.uuid4(),
      metadata: %{}
    )
  end
end
