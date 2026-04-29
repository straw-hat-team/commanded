defmodule Commanded.EventStore.Adapters.EventStore.EventStoreTest do
  use ExUnit.Case

  @moduletag :eventstore_adapter

  alias Commanded.TestSupport.ModuleLoggerLevelHelpers

  setup_all do
    ModuleLoggerLevelHelpers.suppress_module_log_level(DBConnection.Connection, :warning)

    :ok
  end

  setup do
    start_supervised!(EventStoreApplication)

    :ok
  end

  test "should configure event store in application" do
    assert {Commanded.EventStore.Adapters.EventStore, %{event_store: TestEventStore}} =
             Commanded.Application.event_store_adapter(EventStoreApplication)
  end
end
