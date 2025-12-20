if Code.ensure_loaded?(Spear) do
  defmodule Commanded.EventStore.Adapters.KurrentDB.Subscription do
    @moduledoc false

    use GenServer
    require Logger

    alias Commanded.EventStore.Adapters.KurrentDB
    alias Commanded.EventStore.RecordedEvent

    defstruct [
      :conn,
      :stream,
      :subscription_name,
      :subscriber,
      :serializer,
      :subscription_ref,
      :opts,
      pending_acks: %{}
    ]

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    @impl GenServer
    def init(opts) do
      state = %__MODULE__{
        conn: Keyword.fetch!(opts, :conn),
        stream: Keyword.fetch!(opts, :stream),
        subscription_name: Keyword.fetch!(opts, :subscription_name),
        subscriber: Keyword.fetch!(opts, :subscriber),
        serializer: Keyword.get(opts, :serializer),
        opts: Keyword.get(opts, :opts, [])
      }

      Process.monitor(state.subscriber)

      {:ok, state, {:continue, :connect}}
    end

    @impl GenServer
    def handle_continue(:connect, %__MODULE__{} = state) do
      %__MODULE__{
        conn: conn,
        stream: stream,
        subscription_name: subscription_name,
        subscriber: subscriber
      } = state

      case Spear.connect_to_persistent_subscription(
             conn,
             self(),
             stream,
             subscription_name
           ) do
        {:ok, ref} ->
          send(subscriber, {:subscribed, self()})
          {:noreply, %__MODULE__{state | subscription_ref: ref}}

        {:error, reason} ->
          Logger.error(
            "Failed to connect to persistent subscription #{subscription_name}: #{inspect(reason)}"
          )

          {:stop, reason, state}
      end
    end

    @impl GenServer
    def handle_info(%Spear.Event{type: "$" <> _} = event, %__MODULE__{} = state) do
      # Auto-acknowledge system events (those starting with $)
      %__MODULE__{conn: conn, subscription_ref: ref} = state

      if ref do
        Spear.ack(conn, ref, event)
      end

      {:noreply, state}
    end

    @impl GenServer
    def handle_info(%Spear.Event{} = event, %__MODULE__{} = state) do
      # Process non-system events
      %__MODULE__{
        subscriber: subscriber,
        serializer: serializer,
        pending_acks: pending_acks,
        stream: stream
      } = state

      # Determine stream_id based on whether we're subscribed to :all or a specific stream
      stream_id = if stream == :all, do: event.metadata[:stream_name], else: stream

      # Get stream version from event metadata
      stream_revision = Map.get(event.metadata, :stream_revision, 0)
      stream_version = stream_revision + 1

      recorded_event = KurrentDB.from_spear_event(event, stream_id, stream_version, serializer)

      # Track the event for acknowledgment
      pending_acks = Map.put(pending_acks, recorded_event.event_id, event)

      send(subscriber, {:events, [recorded_event]})

      {:noreply, %__MODULE__{state | pending_acks: pending_acks}}
    end

    @impl GenServer
    def handle_info({:ack, %RecordedEvent{event_id: event_id}}, %__MODULE__{} = state) do
      %__MODULE__{conn: conn, subscription_ref: ref, pending_acks: pending_acks} = state

      case Map.pop(pending_acks, event_id) do
        {nil, pending_acks} ->
          Logger.warning("Attempted to ack unknown event: #{event_id}")
          {:noreply, %__MODULE__{state | pending_acks: pending_acks}}

        {spear_event, pending_acks} ->
          Spear.ack(conn, ref, spear_event)
          {:noreply, %__MODULE__{state | pending_acks: pending_acks}}
      end
    end

    @impl GenServer
    def handle_info(:unsubscribe, %__MODULE__{} = state) do
      %__MODULE__{conn: conn, subscription_ref: ref} = state

      if ref do
        Spear.cancel_subscription(conn, ref)
      end

      {:stop, :normal, state}
    end

    @impl GenServer
    def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{subscriber: pid} = state) do
      # Subscriber went down, stop the subscription
      {:stop, :normal, state}
    end

    @impl GenServer
    def handle_info({:eos, ref, reason}, %__MODULE__{subscription_ref: ref} = state) do
      Logger.info("Subscription ended: #{inspect(reason)}")
      {:stop, reason, state}
    end

    @impl GenServer
    def handle_info(_msg, state) do
      {:noreply, state}
    end
  end
end
