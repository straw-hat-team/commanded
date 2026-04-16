defmodule Commanded.EventStore.SnapshotTestCase do
  import Commanded.SharedTestCase

  define_tests do
    alias Commanded.EventStore.AdapterTestData

    describe "record a snapshot" do
      test "should record the snapshot", %{
        event_store: event_store,
        event_store_meta: event_store_meta
      } do
        snapshot = build_snapshot_data(100)

        assert :ok = event_store.record_snapshot(event_store_meta, snapshot)
      end
    end

    describe "read a snapshot" do
      test "should read the snapshot", %{
        event_store: event_store,
        event_store_meta: event_store_meta
      } do
        snapshot1 = build_snapshot_data(100)
        snapshot2 = build_snapshot_data(101)
        snapshot3 = build_snapshot_data(102)

        assert :ok == event_store.record_snapshot(event_store_meta, snapshot1)
        assert :ok == event_store.record_snapshot(event_store_meta, snapshot2)
        assert :ok == event_store.record_snapshot(event_store_meta, snapshot3)

        {:ok, snapshot} = event_store.read_snapshot(event_store_meta, snapshot3.source_uuid)

        assert snapshot.source_uuid == snapshot3.source_uuid
        assert snapshot.source_version == snapshot3.source_version
        assert snapshot.source_type == snapshot3.source_type
        assert snapshot.metadata == snapshot3.metadata
        assert snapshot.data.__struct__ == snapshot3.data.__struct__
        assert snapshot.data.account_number == snapshot3.data.account_number
        assert snapshot.data.balance == snapshot3.data.balance
        assert snapshot.data.state == to_string(snapshot3.data.state)
        assert snapshot_timestamps_within_delta?(snapshot, snapshot3, 60)
      end

      test "should preserve snapshot metadata", %{
        event_store: event_store,
        event_store_meta: event_store_meta
      } do
        metadata = %{
          "request" => %{"actor_id" => "customer-123", "roles" => ["admin", "support"]},
          "trace_id" => "trace-123"
        }

        snapshot = build_snapshot_data(100, metadata: metadata)

        assert :ok == event_store.record_snapshot(event_store_meta, snapshot)

        assert {:ok, read_snapshot} =
                 event_store.read_snapshot(event_store_meta, snapshot.source_uuid)

        assert read_snapshot.metadata == metadata
      end

      test "should error when snapshot does not exist", %{
        event_store: event_store,
        event_store_meta: event_store_meta
      } do
        {:error, :snapshot_not_found} =
          event_store.read_snapshot(event_store_meta, "doesnotexist")
      end
    end

    describe "delete a snapshot" do
      test "should delete the snapshot", %{
        event_store: event_store,
        event_store_meta: event_store_meta
      } do
        snapshot1 = build_snapshot_data(100)

        assert :ok == event_store.record_snapshot(event_store_meta, snapshot1)
        {:ok, snapshot} = event_store.read_snapshot(event_store_meta, snapshot1.source_uuid)

        assert snapshot_timestamps_within_delta?(snapshot, snapshot1, 60)
        assert :ok == event_store.delete_snapshot(event_store_meta, snapshot1.source_uuid)

        assert {:error, :snapshot_not_found} ==
                 event_store.read_snapshot(event_store_meta, snapshot1.source_uuid)
      end
    end

    defp build_snapshot_data(account_number, opts \\ []),
      do: AdapterTestData.build_snapshot_data(account_number, opts)

    defp snapshot_timestamps_within_delta?(snapshot, other_snapshot, delta_seconds) do
      DateTime.diff(snapshot.created_at, other_snapshot.created_at, :second) < delta_seconds
    end
  end
end
