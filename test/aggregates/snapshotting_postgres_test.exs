defmodule Commanded.Aggregates.SnapshottingPostgresTest do
  use ExUnit.Case

  @moduletag :eventstore_adapter

  alias Commanded.Aggregates.{
    Aggregate,
    AppendItemsHandler,
    ExampleAggregate,
    ExecutionContext,
    Supervisor
  }

  alias Commanded.Aggregates.ExampleAggregate.Commands.AppendItems
  alias Commanded.EventStore
  alias Commanded.EventStore.SnapshotData
  alias Commanded.UUID

  defmodule App do
    use Commanded.Application,
      otp_app: :commanded,
      event_store: [
        adapter: Commanded.EventStore.Adapters.EventStore,
        event_store: TestEventStore
      ],
      pubsub: :local,
      registry: :local
  end

  setup do
    start_event_store()
    start_supervised!({App, snapshotting: %{ExampleAggregate => [snapshot_every: 10]}})
    :ok
  end

  test "snapshot data from PostgreSQL matches expected structure" do
    aggregate_uuid = UUID.uuid4()
    append_items(aggregate_uuid, 10)

    assert Aggregate.aggregate_version(App, ExampleAggregate, aggregate_uuid) == 10

    assert {:ok, snapshot} = EventStore.read_snapshot(App, aggregate_uuid)

    assert %SnapshotData{
             source_uuid: ^aggregate_uuid,
             source_version: 10,
             source_type: "Elixir.Commanded.Aggregates.ExampleAggregate",
             data: %ExampleAggregate{
               items: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
               last_index: 10
             },
             metadata: %{"snapshot_module_version" => 1}
           } = snapshot

    assert is_struct(snapshot.data, ExampleAggregate)
    assert snapshot.data.items == Enum.to_list(1..10)
    assert snapshot.data.last_index == 10
  end

  defp append_items(aggregate_uuid, count) do
    execution_context = %ExecutionContext{
      command: %AppendItems{count: count},
      handler: AppendItemsHandler,
      function: :handle
    }

    {:ok, ^aggregate_uuid} =
      Supervisor.open_aggregate(App, ExampleAggregate, aggregate_uuid)

    {:ok, _count, _events, _aggregate_state} =
      Aggregate.execute(App, ExampleAggregate, aggregate_uuid, execution_context)
  end

  defp start_event_store do
    alias Commanded.EventStore.Adapters.EventStore.Storage

    config = Storage.config()

    on_exit(fn ->
      {:ok, conn} = Storage.connect(config)
      Storage.reset!(conn, config)
    end)
  end
end
