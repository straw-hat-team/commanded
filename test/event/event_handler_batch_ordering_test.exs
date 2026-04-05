defmodule Commanded.Event.EventHandlerBatchOrderingTest do
  use ExUnit.Case, async: false

  @moduletag :eventstore_adapter

  # Verifies that events returned by the EventStore arrive ordered by
  # event_number ascending (first = oldest, last = newest), which is the
  # assumption behind using List.first/1 to compute processing_latency_ms
  # for the worst-case (oldest) event in a batch.

  alias Commanded.UUID

  defmodule TestEvent do
    @derive Jason.Encoder
    defstruct [:index]
  end

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
    alias Commanded.EventStore.Adapters.EventStore.Storage

    config = Storage.config()

    on_exit(fn ->
      {:ok, conn} = Storage.connect(config)
      Storage.reset!(conn, config)
    end)

    start_supervised!(App)
    :ok
  end

  test "stream_forward returns events ordered ascending by event_number (first = oldest)" do
    stream_id = UUID.uuid4()

    events =
      Enum.map(1..3, fn index ->
        %Commanded.EventStore.EventData{
          event_type: Atom.to_string(TestEvent),
          data: %TestEvent{index: index},
          metadata: %{}
        }
      end)

    :ok = Commanded.EventStore.append_to_stream(App, stream_id, 0, events)

    recorded_events =
      App
      |> Commanded.EventStore.stream_forward(stream_id)
      |> Enum.to_list()

    assert length(recorded_events) == 3

    event_numbers = Enum.map(recorded_events, & &1.event_number)
    created_ats = Enum.map(recorded_events, & &1.created_at)

    assert event_numbers == Enum.sort(event_numbers),
           "expected events ordered ascending by event_number, got: #{inspect(event_numbers)}"

    assert created_ats == Enum.sort(created_ats, DateTime),
           "expected events ordered ascending by created_at, got: #{inspect(created_ats)}"
  end
end
