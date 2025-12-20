defmodule Commanded.EventStore.Adapters.KurrentDB.KurrentDBTest do
  use Commanded.EventStore.KurrentDBTestCase

  alias Commanded.EventStore.Adapters.KurrentDB
  alias Commanded.EventStore.{EventData, RecordedEvent, SnapshotData}
  alias Commanded.UUID

  @moduletag :kurrent_db

  defmodule BankAccountOpened do
    @derive Jason.Encoder
    defstruct [:account_number, :initial_balance]
  end

  describe "KurrentDB adapter" do
    test "should implement `Commanded.EventStore.Adapter` behaviour", %{
      event_store_meta: _event_store_meta
    } do
      assert_implements(KurrentDB, Commanded.EventStore.Adapter)
    end
  end

  describe "append and read events" do
    test "should append and read events from stream", %{event_store_meta: event_store_meta} do
      stream_uuid = "test-stream-#{UUID.uuid4()}"
      events = build_events(3)

      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 0, events)

      read_events = KurrentDB.stream_forward(event_store_meta, stream_uuid) |> Enum.to_list()

      assert length(read_events) == 3

      for {read_event, index} <- Enum.with_index(read_events, 1) do
        assert %RecordedEvent{} = read_event
        assert read_event.stream_id == stream_uuid
        assert read_event.stream_version == index
        assert read_event.event_type == "#{__MODULE__}.BankAccountOpened"
        assert %BankAccountOpened{} = read_event.data
        assert %DateTime{} = read_event.created_at
      end
    end

    test "should handle wrong expected version", %{event_store_meta: event_store_meta} do
      stream_uuid = "test-stream-#{UUID.uuid4()}"
      events = build_events(1)

      assert {:error, :wrong_expected_version} ==
               KurrentDB.append_to_stream(event_store_meta, stream_uuid, 1, events)
    end

    test "should handle :no_stream expectation", %{event_store_meta: event_store_meta} do
      stream_uuid = "test-stream-#{UUID.uuid4()}"
      events = build_events(1)

      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, :no_stream, events)

      assert {:error, :stream_exists} ==
               KurrentDB.append_to_stream(event_store_meta, stream_uuid, :no_stream, events)
    end

    test "should handle :any_version expectation", %{event_store_meta: event_store_meta} do
      stream_uuid = "test-stream-#{UUID.uuid4()}"

      assert :ok ==
               KurrentDB.append_to_stream(
                 event_store_meta,
                 stream_uuid,
                 :any_version,
                 build_events(1)
               )

      assert :ok ==
               KurrentDB.append_to_stream(
                 event_store_meta,
                 stream_uuid,
                 :any_version,
                 build_events(1)
               )
    end

    test "should return stream not found for unknown stream", %{
      event_store_meta: event_store_meta
    } do
      stream_uuid = "unknown-stream-#{UUID.uuid4()}"

      assert {:error, :stream_not_found} ==
               KurrentDB.stream_forward(event_store_meta, stream_uuid)
    end

    test "should handle :stream_exists expectation", %{event_store_meta: event_store_meta} do
      stream_uuid = "test-stream-#{UUID.uuid4()}"

      # Should fail when stream doesn't exist
      assert {:error, :stream_not_found} ==
               KurrentDB.append_to_stream(
                 event_store_meta,
                 stream_uuid,
                 :stream_exists,
                 build_events(1)
               )

      # Create the stream
      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 0, build_events(1))

      # Should succeed when stream exists
      assert :ok ==
               KurrentDB.append_to_stream(
                 event_store_meta,
                 stream_uuid,
                 :stream_exists,
                 build_events(1)
               )
    end

    test "should read events from a specific version", %{event_store_meta: event_store_meta} do
      stream_uuid = "test-stream-#{UUID.uuid4()}"
      events = build_events(5)

      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 0, events)

      # Read from version 3 (should get events 3, 4, 5)
      read_events =
        KurrentDB.stream_forward(event_store_meta, stream_uuid, 3) |> Enum.to_list()

      assert length(read_events) == 3
      assert Enum.map(read_events, & &1.stream_version) == [3, 4, 5]
    end

    test "should read events in batches", %{event_store_meta: event_store_meta} do
      stream_uuid = "test-stream-#{UUID.uuid4()}"
      events = build_events(10)

      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 0, events)

      # Read with small batch size
      read_events =
        KurrentDB.stream_forward(event_store_meta, stream_uuid, 1, 3) |> Enum.to_list()

      assert length(read_events) == 10
      assert Enum.map(read_events, & &1.stream_version) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    end
  end

  describe "transient subscriptions" do
    test "should subscribe to all streams", %{event_store_meta: event_store_meta} do
      stream_uuid = "test-stream-#{UUID.uuid4()}"

      # Subscribe to all events (transient subscription links to caller)
      :ok = KurrentDB.subscribe(event_store_meta, :all)

      # Append an event
      events = build_events(1)
      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 0, events)

      # Should receive the event
      assert_receive {:events, received_events}, 5_000
      assert length(received_events) >= 1

      # Find our event (there may be other events from concurrent tests)
      our_event = Enum.find(received_events, fn event -> event.stream_id == stream_uuid end)
      assert our_event != nil
      assert %RecordedEvent{} = our_event
    end

    test "should subscribe to a single stream", %{event_store_meta: event_store_meta} do
      stream_uuid = "test-stream-#{UUID.uuid4()}"

      # Append some events first
      events = build_events(2)
      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 0, events)

      # Subscribe to the stream (transient subscription links to caller)
      :ok = KurrentDB.subscribe(event_store_meta, stream_uuid)

      # Append more events
      more_events = build_events(1)
      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 2, more_events)

      # Should receive only the new event
      assert_receive {:events, received_events}, 5_000
      assert length(received_events) == 1
    end
  end

  describe "persistent subscriptions" do
    test "should subscribe to all streams with persistent subscription", %{
      event_store_meta: event_store_meta
    } do
      stream_uuid = "test-stream-#{UUID.uuid4()}"
      subscription_name = "test-subscription-#{UUID.uuid4()}"

      # Subscribe to all events
      {:ok, subscription} =
        KurrentDB.subscribe_to(event_store_meta, :all, subscription_name, self(), :origin, [])

      # Append an event
      events = build_events(1)
      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 0, events)

      # Should receive the event
      assert_receive {:events, received_events}, 5_000

      # Acknowledge the events
      for event <- received_events do
        :ok = KurrentDB.ack_event(event_store_meta, subscription, event)
      end

      # Cleanup
      :ok = KurrentDB.unsubscribe(event_store_meta, subscription)
      :ok = KurrentDB.delete_subscription(event_store_meta, :all, subscription_name)
    end

    test "should subscribe to a single stream with persistent subscription", %{
      event_store_meta: event_store_meta
    } do
      stream_uuid = "test-stream-#{UUID.uuid4()}"
      subscription_name = "test-subscription-#{UUID.uuid4()}"

      # Create stream first
      events = build_events(1)
      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 0, events)

      # Subscribe to the stream
      {:ok, subscription} =
        KurrentDB.subscribe_to(
          event_store_meta,
          stream_uuid,
          subscription_name,
          self(),
          :origin,
          []
        )

      # Append more events
      more_events = build_events(2)
      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 1, more_events)

      # Should receive events (could be 1, 2, or 3 depending on timing)
      assert_receive {:events, received_events}, 5_000
      assert length(received_events) >= 1

      # Acknowledge the events
      for event <- received_events do
        :ok = KurrentDB.ack_event(event_store_meta, subscription, event)
      end

      # Cleanup
      :ok = KurrentDB.unsubscribe(event_store_meta, subscription)
      :ok = KurrentDB.delete_subscription(event_store_meta, stream_uuid, subscription_name)
    end

    test "should resume from last acknowledged event", %{event_store_meta: event_store_meta} do
      stream_uuid = "test-stream-#{UUID.uuid4()}"
      subscription_name = "test-subscription-#{UUID.uuid4()}"

      # Create stream with events
      events = build_events(3)
      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 0, events)

      # First subscription - acknowledge only first event
      {:ok, sub1} =
        KurrentDB.subscribe_to(
          event_store_meta,
          stream_uuid,
          subscription_name,
          self(),
          :origin,
          []
        )

      assert_receive {:events, [first_event | _rest]}, 5_000
      :ok = KurrentDB.ack_event(event_store_meta, sub1, first_event)
      :ok = KurrentDB.unsubscribe(event_store_meta, sub1)

      # Give it a moment
      Process.sleep(100)

      # Second subscription - should resume from event 2
      {:ok, sub2} =
        KurrentDB.subscribe_to(
          event_store_meta,
          stream_uuid,
          subscription_name,
          self(),
          :origin,
          []
        )

      # Should receive remaining events (starting from event 2)
      assert_receive {:events, remaining_events}, 5_000
      assert length(remaining_events) >= 1

      # Cleanup
      :ok = KurrentDB.unsubscribe(event_store_meta, sub2)
      :ok = KurrentDB.delete_subscription(event_store_meta, stream_uuid, subscription_name)
    end
  end

  describe "concurrency settings" do
    test "should create subscription with max_subscriber_count", %{
      event_store_meta: event_store_meta
    } do
      stream_uuid = "test-stream-#{UUID.uuid4()}"
      subscription_name = "test-subscription-#{UUID.uuid4()}"

      # Create stream first
      events = build_events(1)
      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 0, events)

      # Subscribe with max_subscriber_count
      {:ok, subscription} =
        KurrentDB.subscribe_to(
          event_store_meta,
          stream_uuid,
          subscription_name,
          self(),
          :origin,
          max_subscriber_count: 5
        )

      assert is_pid(subscription)

      # Cleanup
      :ok = KurrentDB.unsubscribe(event_store_meta, subscription)
      Process.sleep(200)
      # Delete may fail if connection is closed, which is acceptable
      _ = KurrentDB.delete_subscription(event_store_meta, stream_uuid, subscription_name)
    end

    test "should create subscription with named_consumer_strategy", %{
      event_store_meta: event_store_meta
    } do
      stream_uuid = "test-stream-#{UUID.uuid4()}"
      subscription_name = "test-subscription-#{UUID.uuid4()}"

      # Create stream first
      events = build_events(1)
      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 0, events)

      # Subscribe with Pinned strategy
      {:ok, subscription} =
        KurrentDB.subscribe_to(
          event_store_meta,
          stream_uuid,
          subscription_name,
          self(),
          :origin,
          named_consumer_strategy: :Pinned
        )

      assert is_pid(subscription)

      # Cleanup
      :ok = KurrentDB.unsubscribe(event_store_meta, subscription)
      Process.sleep(200)
      # Delete may fail if connection is closed, which is acceptable
      _ = KurrentDB.delete_subscription(event_store_meta, stream_uuid, subscription_name)
    end

    test "should create subscription with RoundRobin strategy", %{
      event_store_meta: event_store_meta
    } do
      stream_uuid = "test-stream-#{UUID.uuid4()}"
      subscription_name = "test-subscription-#{UUID.uuid4()}"

      # Create stream first
      events = build_events(1)
      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 0, events)

      # Subscribe with RoundRobin strategy
      {:ok, subscription} =
        KurrentDB.subscribe_to(
          event_store_meta,
          stream_uuid,
          subscription_name,
          self(),
          :origin,
          named_consumer_strategy: :RoundRobin
        )

      assert is_pid(subscription)

      # Cleanup
      :ok = KurrentDB.unsubscribe(event_store_meta, subscription)
      Process.sleep(200)
      # Delete may fail if connection is closed, which is acceptable
      _ = KurrentDB.delete_subscription(event_store_meta, stream_uuid, subscription_name)
    end

    test "should create subscription with all concurrency options", %{
      event_store_meta: event_store_meta
    } do
      stream_uuid = "test-stream-#{UUID.uuid4()}"
      subscription_name = "test-subscription-#{UUID.uuid4()}"

      # Create stream first
      events = build_events(1)
      assert :ok == KurrentDB.append_to_stream(event_store_meta, stream_uuid, 0, events)

      # Subscribe with all options
      {:ok, subscription} =
        KurrentDB.subscribe_to(
          event_store_meta,
          stream_uuid,
          subscription_name,
          self(),
          :origin,
          max_subscriber_count: 3,
          named_consumer_strategy: :RoundRobin,
          message_timeout: 10_000,
          checkpoint_after: 5_000
        )

      assert is_pid(subscription)

      # Cleanup
      :ok = KurrentDB.unsubscribe(event_store_meta, subscription)
      Process.sleep(200)
      # Delete may fail if connection is closed, which is acceptable
      _ = KurrentDB.delete_subscription(event_store_meta, stream_uuid, subscription_name)
    end
  end

  describe "snapshots" do
    test "should record and read snapshot", %{event_store_meta: event_store_meta} do
      source_uuid = "aggregate-#{UUID.uuid4()}"

      snapshot = %SnapshotData{
        source_uuid: source_uuid,
        source_version: 5,
        source_type: "#{__MODULE__}.BankAccountOpened",
        data: %BankAccountOpened{account_number: "123", initial_balance: 1000},
        metadata: %{"user_id" => "user-1"}
      }

      assert :ok == KurrentDB.record_snapshot(event_store_meta, snapshot)

      assert {:ok, read_snapshot} = KurrentDB.read_snapshot(event_store_meta, source_uuid)

      assert read_snapshot.source_uuid == source_uuid
      assert read_snapshot.source_version == 5
      assert read_snapshot.source_type == "#{__MODULE__}.BankAccountOpened"
      assert %BankAccountOpened{} = read_snapshot.data
      assert read_snapshot.data.account_number == "123"
      assert %DateTime{} = read_snapshot.created_at
    end

    test "should return snapshot not found for unknown source", %{
      event_store_meta: event_store_meta
    } do
      source_uuid = "unknown-aggregate-#{UUID.uuid4()}"

      assert {:error, :snapshot_not_found} ==
               KurrentDB.read_snapshot(event_store_meta, source_uuid)
    end

    test "should delete snapshot", %{event_store_meta: event_store_meta} do
      source_uuid = "aggregate-#{UUID.uuid4()}"

      snapshot = %SnapshotData{
        source_uuid: source_uuid,
        source_version: 5,
        source_type: "#{__MODULE__}.BankAccountOpened",
        data: %BankAccountOpened{account_number: "123", initial_balance: 1000},
        metadata: %{}
      }

      assert :ok == KurrentDB.record_snapshot(event_store_meta, snapshot)
      assert {:ok, _snapshot} = KurrentDB.read_snapshot(event_store_meta, source_uuid)

      assert :ok == KurrentDB.delete_snapshot(event_store_meta, source_uuid)

      assert {:error, :snapshot_not_found} ==
               KurrentDB.read_snapshot(event_store_meta, source_uuid)
    end
  end

  defp assert_implements(module, behaviour) do
    all = Keyword.take(module.__info__(:attributes), [:behaviour])

    assert [behaviour] in Keyword.values(all)
  end

  defp build_event(account_number) do
    %EventData{
      causation_id: UUID.uuid4(),
      correlation_id: UUID.uuid4(),
      event_type: "#{__MODULE__}.BankAccountOpened",
      data: %BankAccountOpened{account_number: account_number, initial_balance: 1_000},
      metadata: %{"user_id" => "test"}
    }
  end

  defp build_events(count) do
    for account_number <- 1..count, do: build_event("ACC-#{account_number}")
  end
end
