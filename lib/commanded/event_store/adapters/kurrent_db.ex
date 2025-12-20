if Code.ensure_loaded?(Spear) do
  defmodule Commanded.EventStore.Adapters.KurrentDB do
    @moduledoc """
    KurrentDB/EventStoreDB v23 Adapter for Commanded using the Spear gRPC client.

    ## Configuration

        config :my_app, MyApp.Application,
          event_store: [
            adapter: Commanded.EventStore.Adapters.KurrentDB,
            connection_string: "esdb://localhost:2113",
            # Optional TLS configuration
            mint_opts: [transport_opts: [cacertfile: "/path/to/ca.crt"]],
            # Optional serializer
            serializer: MyApp.JsonSerializer
          ]

    ## Connection String

    The connection string follows the EventStoreDB format:

        esdb://localhost:2113
        esdb://user:password@localhost:2113?tls=true

    ## Snapshots

    Since EventStoreDB doesn't have native snapshot support, snapshots are stored
    as events in dedicated streams with the prefix `snapshot-`. For example,
    snapshots for aggregate `123` are stored in stream `snapshot-123`.

    ## Persistent Subscriptions

    Persistent subscriptions support native concurrency through EventStoreDB's
    consumer groups. You can configure concurrency settings when subscribing:

        Commanded.EventStore.subscribe_to(
          :all,
          "my-subscription",
          MyHandler,
          :origin,
          max_subscriber_count: 5,
          named_consumer_strategy: :RoundRobin
        )

    ### Subscription Options

    * `max_subscriber_count` (integer, default: 1) - Maximum number of concurrent
      consumers that can connect to the subscription. EventStoreDB will distribute
      events across these consumers.

    * `named_consumer_strategy` (atom, default: `:RoundRobin`) - Strategy for
      distributing events to multiple consumers:
      * `:RoundRobin` - Events are distributed evenly across all consumers
      * `:Pinned` - Events from the same stream always go to the same consumer
        (useful for maintaining ordering per stream)
      * `:DispatchToSingle` - All events go to a single consumer

    * `message_timeout` (integer, default: 5000) - Timeout in milliseconds before
      a message is considered failed and re-delivered.

    * `checkpoint_after` (integer, default: 3000) - Checkpoint interval in
      milliseconds. The subscription will checkpoint after processing this many
      events or after this duration.
    """

    @behaviour Commanded.EventStore.Adapter

    alias Commanded.EventStore.Adapters.KurrentDB.Subscription
    alias Commanded.EventStore.{EventData, RecordedEvent, SnapshotData}
    alias Commanded.UUID

    @snapshot_stream_prefix "snapshot-"
    @snapshot_event_type "$snapshot"

    @impl Commanded.EventStore.Adapter
    def child_spec(application, config) do
      {connection_string, config} = Keyword.pop!(config, :connection_string)
      name = Keyword.get(config, :name, Module.concat([application, KurrentDB]))
      serializer = Keyword.get(config, :serializer)

      conn_name = connection_name(name)
      supervisor_name = subscriptions_supervisor_name(name)

      connection_opts =
        [connection_string: connection_string, name: conn_name]
        |> Keyword.merge(Keyword.take(config, [:mint_opts]))

      child_spec = [
        {DynamicSupervisor, strategy: :one_for_one, name: supervisor_name},
        %{
          id: conn_name,
          start: {Spear.Connection, :start_link, [connection_opts]}
        }
      ]

      adapter_meta = %{
        name: name,
        conn: conn_name,
        serializer: serializer
      }

      {:ok, child_spec, adapter_meta}
    end

    @impl Commanded.EventStore.Adapter
    def append_to_stream(adapter_meta, stream_uuid, expected_version, events, _opts \\ []) do
      %{conn: conn, serializer: serializer} = adapter_meta

      spear_events = Enum.map(events, &to_spear_event(&1, serializer))
      expect_opts = to_expected_version_opts(expected_version)

      case Spear.append(spear_events, conn, stream_uuid, expect_opts) do
        :ok ->
          :ok

        {:error, %Spear.ExpectationViolation{current: :empty}} ->
          # Stream doesn't exist
          if expected_version == :stream_exists do
            {:error, :stream_not_found}
          else
            {:error, :wrong_expected_version}
          end

        {:error, %Spear.ExpectationViolation{current: current}} when is_integer(current) ->
          # Stream exists with a different version
          if expected_version == :no_stream do
            {:error, :stream_exists}
          else
            {:error, :wrong_expected_version}
          end

        {:error, %Spear.ExpectationViolation{}} ->
          {:error, :wrong_expected_version}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl Commanded.EventStore.Adapter
    def stream_forward(adapter_meta, stream_uuid, start_version \\ 0, read_batch_size \\ 1_000) do
      %{conn: conn, serializer: serializer} = adapter_meta

      # Commanded uses 1-based versions, EventStoreDB uses 0-based revisions
      from = if start_version <= 1, do: :start, else: start_version - 1

      # EventStoreDB returns an empty stream for non-existent streams
      # We need to check if the stream has any events to distinguish
      with {:ok, first_event_stream} <- Spear.read_stream(conn, stream_uuid, from: from, max_count: 1),
           true <- stream_has_events?(first_event_stream) do
        # Stream exists, return the full lazy stream
        build_event_stream(conn, stream_uuid, from, read_batch_size, start_version, serializer)
      else
        false ->
          {:error, :stream_not_found}

        {:error, %Spear.Grpc.Response{status: :not_found}} ->
          {:error, :stream_not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp stream_has_events?(event_stream) do
      Enum.take(event_stream, 1) != []
    end

    defp build_event_stream(conn, stream_uuid, from, read_batch_size, start_version, serializer) do
      conn
      |> Spear.stream!(stream_uuid, from: from, chunk_size: read_batch_size)
      |> Stream.with_index(max(start_version, 1))
      |> Stream.map(fn {event, stream_version} ->
        from_spear_event(event, stream_uuid, stream_version, serializer)
      end)
    end

    @impl Commanded.EventStore.Adapter
    def subscribe(adapter_meta, :all) do
      %{conn: conn, serializer: serializer} = adapter_meta
      subscriber = self()

      # Spawn a process to receive events from Spear and forward them to the subscriber
      forwarder = spawn_link(fn -> forward_events_loop(subscriber, serializer, :all) end)

      # Subscribe with the forwarder as the actual subscriber
      {:ok, _ref} = Spear.subscribe(conn, forwarder, :all, from: :end)

      :ok
    end

    @impl Commanded.EventStore.Adapter
    def subscribe(adapter_meta, stream_uuid) do
      %{conn: conn, serializer: serializer} = adapter_meta
      subscriber = self()

      # Spawn a process to receive events from Spear and forward them to the subscriber
      forwarder = spawn_link(fn -> forward_events_loop(subscriber, serializer, stream_uuid) end)

      # Subscribe with the forwarder as the actual subscriber
      {:ok, _ref} = Spear.subscribe(conn, forwarder, stream_uuid, from: :end)

      :ok
    end

    @impl Commanded.EventStore.Adapter
    def subscribe_to(adapter_meta, :all, subscription_name, subscriber, start_from, opts) do
      subscribe_to_stream(adapter_meta, :all, subscription_name, subscriber, start_from, opts)
    end

    @impl Commanded.EventStore.Adapter
    def subscribe_to(adapter_meta, stream_uuid, subscription_name, subscriber, start_from, opts) do
      subscribe_to_stream(
        adapter_meta,
        stream_uuid,
        subscription_name,
        subscriber,
        start_from,
        opts
      )
    end

    @impl Commanded.EventStore.Adapter
    def ack_event(_adapter_meta, subscription, %RecordedEvent{} = event)
        when is_pid(subscription) do
      send(subscription, {:ack, event})
      :ok
    end

    @impl Commanded.EventStore.Adapter
    def unsubscribe(_adapter_meta, subscription) when is_pid(subscription) do
      send(subscription, :unsubscribe)
      :ok
    end

    @impl Commanded.EventStore.Adapter
    def delete_subscription(adapter_meta, :all, subscription_name) do
      do_delete_subscription(adapter_meta, :all, subscription_name)
    end

    @impl Commanded.EventStore.Adapter
    def delete_subscription(adapter_meta, stream_uuid, subscription_name) do
      do_delete_subscription(adapter_meta, stream_uuid, subscription_name)
    end

    @impl Commanded.EventStore.Adapter
    def read_snapshot(adapter_meta, source_uuid) do
      %{conn: conn, serializer: serializer} = adapter_meta
      snapshot_stream = @snapshot_stream_prefix <> source_uuid

      try do
        case conn
             |> Spear.stream!(snapshot_stream, from: :end, direction: :backwards, chunk_size: 1)
             |> Enum.take(1) do
          [event] ->
            snapshot = from_spear_snapshot(event, serializer)
            {:ok, snapshot}

          [] ->
            {:error, :snapshot_not_found}
        end
      rescue
        error in Spear.Grpc.Response ->
          case error.status do
            :not_found -> {:error, :snapshot_not_found}
            _ -> {:error, error}
          end
      end
    end

    @impl Commanded.EventStore.Adapter
    def record_snapshot(adapter_meta, %SnapshotData{} = snapshot) do
      %{conn: conn, serializer: serializer} = adapter_meta
      %SnapshotData{source_uuid: source_uuid} = snapshot

      snapshot_stream = @snapshot_stream_prefix <> source_uuid
      event = to_spear_snapshot(snapshot, serializer)

      case Spear.append([event], conn, snapshot_stream) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Commanded.EventStore.Adapter
    def delete_snapshot(adapter_meta, source_uuid) do
      %{conn: conn} = adapter_meta
      snapshot_stream = @snapshot_stream_prefix <> source_uuid

      case Spear.delete_stream(conn, snapshot_stream) do
        :ok ->
          :ok

        {:error, %Spear.Grpc.Response{status: :not_found}} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end

    # Private helpers

    defp connection_name(name), do: Module.concat([name, Connection])
    defp subscriptions_supervisor_name(name), do: Module.concat([name, SubscriptionsSupervisor])

    defp to_expected_version_opts(:any_version), do: []
    defp to_expected_version_opts(:no_stream), do: [expect: :empty]
    defp to_expected_version_opts(:stream_exists), do: [expect: :exists]

    defp to_expected_version_opts(version) when is_integer(version) and version >= 0 do
      # Commanded uses 1-based versions, EventStoreDB uses 0-based revisions
      [expect: version - 1]
    end

    defp start_from_to_position(:origin), do: :start
    defp start_from_to_position(:current), do: :end
    defp start_from_to_position(position) when is_integer(position), do: position

    defp build_subscription_settings(opts) do
      base = %Spear.PersistentSubscription.Settings{}

      base
      |> maybe_put_setting(opts, :max_subscriber_count)
      |> maybe_put_setting(opts, :named_consumer_strategy)
      |> maybe_put_setting(opts, :message_timeout)
      |> maybe_put_setting(opts, :checkpoint_after)
    end

    defp maybe_put_setting(settings, opts, key) do
      case Keyword.get(opts, key) do
        nil -> settings
        value -> Map.put(settings, key, value)
      end
    end

    defp subscribe_to_stream(
           adapter_meta,
           stream,
           subscription_name,
           subscriber,
           start_from,
           opts
         ) do
      %{name: name, conn: conn, serializer: serializer} = adapter_meta

      supervisor = subscriptions_supervisor_name(name)

      # Build settings from opts to support native concurrency
      settings = build_subscription_settings(opts)
      from_position = start_from_to_position(start_from)

      # Try to create the subscription - may fail if already exists
      _ = create_persistent_subscription(conn, stream, subscription_name, settings, from_position)

      # Start subscription process
      subscription_opts = [
        conn: conn,
        stream: stream,
        subscription_name: subscription_name,
        subscriber: subscriber,
        serializer: serializer,
        opts: opts
      ]

      case DynamicSupervisor.start_child(supervisor, {Subscription, subscription_opts}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end

    defp create_persistent_subscription(conn, :all, subscription_name, settings, from_position) do
      Spear.create_persistent_subscription(conn, :all, subscription_name, settings,
        from: from_position
      )
    end

    defp create_persistent_subscription(conn, stream, subscription_name, settings, from_position) do
      Spear.create_persistent_subscription(conn, stream, subscription_name, settings,
        from: from_position
      )
    end

    defp do_delete_subscription(adapter_meta, stream, subscription_name) do
      %{conn: conn} = adapter_meta

      case Spear.delete_persistent_subscription(conn, stream, subscription_name) do
        :ok ->
          :ok

        {:error, %Spear.Grpc.Response{status: :not_found}} ->
          {:error, :subscription_not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp to_spear_event(%EventData{} = event_data, serializer) do
      %EventData{
        causation_id: causation_id,
        correlation_id: correlation_id,
        event_type: event_type,
        data: data,
        metadata: metadata,
        event_id: event_id
      } = event_data

      # Serialize data if serializer is configured
      serialized_data = serialize(data, serializer)

      # Build custom metadata with causation and correlation IDs
      # Custom metadata must be encoded as JSON for EventStoreDB system projections
      custom_metadata =
        (metadata || %{})
        |> maybe_put("$causationId", causation_id)
        |> maybe_put("$correlationId", correlation_id)
        |> Jason.encode!()

      Spear.Event.new(event_type, serialized_data,
        id: event_id || UUID.uuid7(),
        custom_metadata: custom_metadata
      )
    end

    @doc false
    def from_spear_event(%Spear.Event{} = event, stream_uuid, stream_version, serializer) do
      %Spear.Event{
        id: event_id,
        type: event_type,
        body: data,
        metadata: event_metadata
      } = event

      # Deserialize data if serializer is configured
      deserialized_data = deserialize(data, event_type, serializer)

      # Extract custom_metadata from event metadata (it's stored inside metadata map)
      custom_metadata = Map.get(event_metadata, :custom_metadata, <<>>)

      # Deserialize custom metadata
      deserialized_metadata = deserialize_metadata(custom_metadata, serializer)

      # Extract system metadata
      commit_position = Map.get(event_metadata, :commit_position, 0)
      created = Map.get(event_metadata, :created, DateTime.utc_now())

      # Extract causation/correlation IDs from custom metadata
      causation_id = Map.get(deserialized_metadata, "$causationId")
      correlation_id = Map.get(deserialized_metadata, "$correlationId")

      # Remove system fields from metadata
      clean_metadata = Map.drop(deserialized_metadata, ["$causationId", "$correlationId"])

      %RecordedEvent{
        event_id: event_id,
        event_number: commit_position,
        stream_id: stream_uuid,
        stream_version: stream_version,
        causation_id: causation_id,
        correlation_id: correlation_id,
        event_type: event_type,
        data: deserialized_data,
        metadata: clean_metadata,
        created_at: created
      }
    end

    defp to_spear_snapshot(%SnapshotData{} = snapshot, serializer) do
      %SnapshotData{
        source_uuid: source_uuid,
        source_version: source_version,
        source_type: source_type,
        data: data,
        metadata: metadata
      } = snapshot

      serialized_data = serialize(data, serializer)

      # Custom metadata must be encoded as JSON for Spear
      custom_metadata =
        Jason.encode!(%{
          "source_uuid" => source_uuid,
          "source_version" => source_version,
          "source_type" => source_type,
          "metadata" => serialize(metadata, serializer)
        })

      Spear.Event.new(@snapshot_event_type, serialized_data,
        id: UUID.uuid7(),
        custom_metadata: custom_metadata
      )
    end

    defp from_spear_snapshot(%Spear.Event{} = event, serializer) do
      %Spear.Event{
        body: data,
        metadata: event_metadata
      } = event

      created = Map.get(event_metadata, :created, DateTime.utc_now())

      # Extract custom_metadata from event metadata (it's stored inside metadata map)
      custom_metadata_raw = Map.get(event_metadata, :custom_metadata, <<>>)

      # Decode the custom metadata JSON
      custom_metadata =
        case custom_metadata_raw do
          <<>> -> %{}
          binary when is_binary(binary) -> Jason.decode!(binary)
          map when is_map(map) -> map
        end

      source_type = custom_metadata["source_type"]
      deserialized_data = deserialize(data, source_type, serializer)

      metadata = custom_metadata["metadata"]
      deserialized_metadata = deserialize_metadata(metadata, serializer)

      %SnapshotData{
        source_uuid: custom_metadata["source_uuid"],
        source_version: custom_metadata["source_version"],
        source_type: source_type,
        data: deserialized_data,
        metadata: deserialized_metadata,
        created_at: created
      }
    end

    defp forward_events_loop(subscriber, serializer, stream) do
      receive do
        %Spear.Event{type: "$" <> _} ->
          # Skip system events (those starting with $)
          forward_events_loop(subscriber, serializer, stream)

        %Spear.Event{} = event ->
          # Process non-system events
          stream_id = if stream == :all, do: event.metadata[:stream_name], else: stream

          # For transient subscriptions, we use stream_version from the event metadata
          stream_revision = Map.get(event.metadata, :stream_revision, 0)
          stream_version = stream_revision + 1

          recorded = from_spear_event(event, stream_id, stream_version, serializer)
          send(subscriber, {:events, [recorded]})
          forward_events_loop(subscriber, serializer, stream)

        {:eos, _ref, _reason} ->
          :ok

        {:caught_up, _ref} ->
          # Ignore caught up notifications
          forward_events_loop(subscriber, serializer, stream)

        :stop ->
          :ok

        _other ->
          # Ignore other messages
          forward_events_loop(subscriber, serializer, stream)
      end
    end

    defp serialize(data, nil), do: data
    defp serialize(data, serializer), do: serializer.serialize(data)

    defp deserialize(data, _type, nil), do: data
    defp deserialize(data, type, serializer), do: serializer.deserialize(data, type: type)

    defp deserialize_metadata(nil, _serializer), do: %{}
    defp deserialize_metadata(<<>>, _serializer), do: %{}

    defp deserialize_metadata(metadata, _serializer) when is_binary(metadata) do
      case Jason.decode(metadata) do
        {:ok, decoded} -> decoded
        {:error, _} -> %{}
      end
    end

    defp deserialize_metadata(metadata, _serializer) when is_map(metadata), do: metadata

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)
  end
end
