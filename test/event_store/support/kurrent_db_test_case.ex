defmodule Commanded.EventStore.KurrentDBTestCase do
  @moduledoc """
  Test case for KurrentDB/EventStoreDB adapter tests.

  Requires a running EventStoreDB v23 instance on localhost:2113.

  To start EventStoreDB for testing:

      docker run -d --name eventstoredb -p 2113:2113 \\
        -e EVENTSTORE_INSECURE=true \\
        -e EVENTSTORE_RUN_PROJECTIONS=All \\
        -e EVENTSTORE_START_STANDARD_PROJECTIONS=true \\
        eventstore/eventstore:23.10.0-bookworm-slim

  """

  use ExUnit.CaseTemplate

  alias Commanded.EventStore.Adapters.KurrentDB
  alias Commanded.Serialization.JsonSerializer
  alias Commanded.UUID

  @connection_string System.get_env(
                       "EVENTSTORE_CONNECTION_STRING",
                       "esdb://localhost:2113?tls=false"
                     )

  setup do
    # Use a unique name for each test to avoid conflicts
    test_name = :"KurrentDB_#{UUID.uuid4()}"

    config = [
      connection_string: @connection_string,
      name: test_name,
      serializer: JsonSerializer
    ]

    {:ok, child_spec, event_store_meta} = KurrentDB.child_spec(KurrentDB, config)

    for child <- child_spec do
      start_supervised!(child)
    end

    on_exit(fn ->
      cleanup_subscriptions(event_store_meta)
    end)

    [event_store_meta: event_store_meta]
  end

  defp cleanup_subscriptions(_event_store_meta) do
    # Subscriptions are cleaned up when the test process exits
    :ok
  end
end
