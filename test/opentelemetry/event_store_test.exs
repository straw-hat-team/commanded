defmodule Commanded.OpenTelemetry.EventStoreTest do
  @moduledoc """
  Tests for EventStore OpenTelemetry instrumentation.

  Follows the same patterns as ApplicationTest, AggregateTest, etc.
  """

  use Commanded.OpenTelemetryCase, async: false

  import Commanded.TestSupport.Factory

  alias Commanded.Application, as: CommandedApplication
  alias Commanded.Application.Config, as: AppConfig
  alias Commanded.DefaultApp
  alias Commanded.EventStore
  alias Commanded.EventStore.{EventData, SnapshotData}
  alias Commanded.OpenTelemetry.EventStore, as: OTelEventStore
  alias Commanded.UUID

  @events ~w(
    ack_event
    append_to_stream
    delete_snapshot
    delete_subscription
    read_snapshot
    record_snapshot
    stream_forward
    subscribe
    subscribe_to
    unsubscribe
  )a

  setup do
    detach_handlers()
    OTelEventStore.setup()

    :ok
  end

  describe "setup/0" do
    test "attaches telemetry handlers for event store operations" do
      detach_handlers()

      OTelEventStore.setup()

      for event <- @events do
        for suffix <- [:start, :stop, :exception] do
          handlers = :telemetry.list_handlers([:commanded, :event_store, event, suffix])

          assert Enum.any?(
                   handlers,
                   &match?(%{id: {OTelEventStore, ^event}}, &1)
                 ),
                 "Expected handler for event [:commanded, :event_store, #{event}, #{suffix}]"
        end
      end
    end

    test "calling setup twice raises MatchError (fail fast)" do
      detach_handlers()

      :ok = OTelEventStore.setup()

      handlers = :telemetry.list_handlers([:commanded, :event_store, :append_to_stream, :start])
      assert length(handlers) == 1

      assert_raise MatchError, fn ->
        OTelEventStore.setup()
      end
    end
  end

  describe "runtime spans" do
    setup do
      start_supervised!(DefaultApp)

      [destination_name: expected_event_store_destination(DefaultApp)]
    end

    test "append_to_stream uses the configured event store as destination", %{
      destination_name: destination_name
    } do
      stream_uuid = UUID.uuid4()

      assert :ok = EventStore.append_to_stream(DefaultApp, stream_uuid, 0, [%EventData{}])

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("append_to_stream #{destination_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "append_to_stream",
               "messaging.destination.name": destination_name,
               "code.function": "append_to_stream",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": stream_uuid,
               "commanded.expected_version": 0
             }
    end

    test "stream_forward uses the configured event store as destination", %{
      destination_name: destination_name
    } do
      stream_uuid = UUID.uuid4()

      assert :ok = EventStore.append_to_stream(DefaultApp, stream_uuid, 0, [%EventData{}])
      _ = assert_receive_span_named("append_to_stream #{destination_name}")

      assert [_event] = EventStore.stream_forward(DefaultApp, stream_uuid, 0)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("stream_forward #{destination_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "stream_forward",
               "messaging.destination.name": destination_name,
               "code.function": "stream_forward",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": stream_uuid
             }
    end

    test "subscribe_to uses the configured event store as destination", %{
      destination_name: destination_name
    } do
      subscription_name = unique_subscription_name()

      assert {:ok, subscription} =
               EventStore.subscribe_to(DefaultApp, :all, subscription_name, self(), :origin)

      assert_receive {:subscribed, ^subscription}, 1000

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("subscribe_to #{destination_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "subscribe_to",
               "messaging.destination.name": destination_name,
               "messaging.destination.subscription.name": subscription_name,
               "code.function": "subscribe_to",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": :all,
               "commanded.subscription.name": subscription_name,
               "commanded.start_from": "origin"
             }
    end

    test "ack_event uses the configured event store as destination", %{
      destination_name: destination_name
    } do
      subscription_name = unique_subscription_name()
      stream_uuid = UUID.uuid4()

      assert {:ok, subscription} =
               EventStore.subscribe_to(DefaultApp, :all, subscription_name, self(), :origin)

      assert_receive {:subscribed, ^subscription}, 1000
      _ = assert_receive_span_named("subscribe_to #{destination_name}")

      assert :ok = EventStore.append_to_stream(DefaultApp, stream_uuid, 0, [%EventData{}])
      assert_receive {:events, [event]}, 1000
      _ = assert_receive_span_named("append_to_stream #{destination_name}")

      assert :ok = EventStore.ack_event(DefaultApp, subscription, event)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("ack_event #{destination_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :settle,
               "messaging.operation.name": "ack_event",
               "messaging.destination.name": destination_name,
               "code.function": "ack_event",
               "commanded.application": DefaultApp
             }
    end

    test "record_snapshot uses the configured event store as destination", %{
      destination_name: destination_name
    } do
      source_uuid = UUID.uuid4()
      snapshot = build_snapshot(source_uuid)

      assert :ok = EventStore.record_snapshot(DefaultApp, snapshot)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("record_snapshot #{destination_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "record_snapshot",
               "messaging.destination.name": destination_name,
               "code.function": "record_snapshot",
               "commanded.application": DefaultApp,
               "commanded.source.uuid": source_uuid
             }
    end

    test "read_snapshot uses the configured event store as destination", %{
      destination_name: destination_name
    } do
      source_uuid = UUID.uuid4()
      snapshot = build_snapshot(source_uuid)

      assert :ok = EventStore.record_snapshot(DefaultApp, snapshot)
      _ = assert_receive_span_named("record_snapshot #{destination_name}")

      assert {:ok, %SnapshotData{source_uuid: ^source_uuid}} =
               EventStore.read_snapshot(DefaultApp, source_uuid)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("read_snapshot #{destination_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "read_snapshot",
               "messaging.destination.name": destination_name,
               "code.function": "read_snapshot",
               "commanded.application": DefaultApp,
               "commanded.source.uuid": source_uuid
             }
    end

    test "delete_snapshot uses the configured event store as destination", %{
      destination_name: destination_name
    } do
      source_uuid = UUID.uuid4()
      snapshot = build_snapshot(source_uuid)

      assert :ok = EventStore.record_snapshot(DefaultApp, snapshot)
      _ = assert_receive_span_named("record_snapshot #{destination_name}")

      assert :ok = EventStore.delete_snapshot(DefaultApp, source_uuid)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("delete_snapshot #{destination_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.name": "delete_snapshot",
               "messaging.destination.name": destination_name,
               "code.function": "delete_snapshot",
               "commanded.application": DefaultApp,
               "commanded.source.uuid": source_uuid
             }
    end

    test "subscribe uses the configured event store as destination", %{
      destination_name: destination_name
    } do
      stream_uuid = UUID.uuid4()

      assert :ok = EventStore.subscribe(DefaultApp, stream_uuid)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("subscribe #{destination_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "subscribe",
               "messaging.destination.name": destination_name,
               "code.function": "subscribe",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": stream_uuid
             }
    end

    test "unsubscribe uses the configured event store as destination", %{
      destination_name: destination_name
    } do
      subscription_name = unique_subscription_name()

      assert {:ok, subscription} =
               EventStore.subscribe_to(DefaultApp, :all, subscription_name, self(), :origin)

      assert_receive {:subscribed, ^subscription}, 1000
      _ = assert_receive_span_named("subscribe_to #{destination_name}")

      assert :ok = EventStore.unsubscribe(DefaultApp, subscription)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("unsubscribe #{destination_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.name": "unsubscribe",
               "messaging.destination.name": destination_name,
               "code.function": "unsubscribe",
               "commanded.application": DefaultApp
             }
    end

    test "delete_subscription uses the configured event store as destination", %{
      destination_name: destination_name
    } do
      subscription_name = unique_subscription_name()

      assert {:ok, subscription} =
               EventStore.subscribe_to(DefaultApp, :all, subscription_name, self(), :origin)

      assert_receive {:subscribed, ^subscription}, 1000
      _ = assert_receive_span_named("subscribe_to #{destination_name}")

      assert :ok = EventStore.unsubscribe(DefaultApp, subscription)
      _ = assert_receive_span_named("unsubscribe #{destination_name}")

      assert :ok = EventStore.delete_subscription(DefaultApp, :all, subscription_name)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("delete_subscription #{destination_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.name": "delete_subscription",
               "messaging.destination.name": destination_name,
               "code.function": "delete_subscription",
               "commanded.application": DefaultApp
             }
    end

    test "missing streams still keep the real destination on the span", %{
      destination_name: destination_name
    } do
      stream_uuid = UUID.uuid4()

      assert {:error, :stream_not_found} = EventStore.stream_forward(DefaultApp, stream_uuid)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("stream_forward #{destination_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "stream_forward",
               "messaging.destination.name": destination_name,
               "code.function": "stream_forward",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": stream_uuid
             }
    end
  end

  describe "defensive destination lookup" do
    test "emits a telemetry warning when application lookup fails" do
      warning_handler = attach_warning_handler()
      on_exit(fn -> :telemetry.detach(warning_handler) end)

      stream_uuid = UUID.uuid4()
      application = MissingApplication

      assert_raise RuntimeError, fn ->
        EventStore.append_to_stream(application, stream_uuid, 0, [%EventData{}])
      end

      assert_receive {:warning, [:commanded, :opentelemetry, :warning], %{count: 1},
                      %{
                        message:
                          "Failed to resolve event store adapter metadata, leaving event store destination unset",
                        application: ^application,
                        error: %RuntimeError{},
                        tracer_id: OTelEventStore
                      }}
    end

    test "emits a telemetry warning when application input is malformed" do
      warning_handler = attach_warning_handler()
      on_exit(fn -> :telemetry.detach(warning_handler) end)

      stream_uuid = UUID.uuid4()
      application = "not-an-application"

      assert_raise FunctionClauseError, fn ->
        EventStore.append_to_stream(application, stream_uuid, 0, [%EventData{}])
      end

      assert_receive {:warning, [:commanded, :opentelemetry, :warning], %{count: 1},
                      %{
                        message:
                          "Failed to resolve event store adapter metadata, leaving event store destination unset",
                        application: ^application,
                        error: %FunctionClauseError{},
                        tracer_id: OTelEventStore
                      }}
    end

    setup do
      start_supervised!(DefaultApp)

      :ok
    end

    test "keeps the telemetry handler attached when event store config is nil" do
      warning_handler = attach_warning_handler()
      on_exit(fn -> :telemetry.detach(warning_handler) end)

      stream_uuid = UUID.uuid4()

      AppConfig.__put__(DefaultApp, :event_store, nil)

      assert_raise MatchError, fn ->
        EventStore.append_to_stream(DefaultApp, stream_uuid, 0, [%EventData{}])
      end

      assert span(
               name: "append_to_stream",
               status: {:status, :error, error_message},
               attributes: attributes,
               events: events
             ) = assert_receive_span_named("append_to_stream")

      assert error_message =~ "(MatchError)"

      assert_receive {:warning, [:commanded, :opentelemetry, :warning], %{count: 1},
                      %{
                        message:
                          "Failed to resolve event store adapter metadata, leaving event store destination unset",
                        application: DefaultApp,
                        error: %MatchError{},
                        tracer_id: OTelEventStore
                      }}

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "append_to_stream",
               "code.function": "append_to_stream",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": stream_uuid,
               "commanded.expected_version": 0,
               "erlang.exception.kind": :error,
               "error.type": "Elixir.MatchError"
             }

      assert_exception_event(events, "Elixir.MatchError")
      assert_handler_attached(:append_to_stream)
    end

    test "keeps the telemetry handler attached when adapter metadata is not a map" do
      stream_uuid = UUID.uuid4()

      AppConfig.__put__(
        DefaultApp,
        :event_store,
        {Commanded.EventStore.Adapters.InMemory, :not_a_map}
      )

      assert_raise FunctionClauseError, fn ->
        EventStore.append_to_stream(DefaultApp, stream_uuid, 0, [%EventData{}])
      end

      assert span(
               name: "append_to_stream",
               status: {:status, :error, error_message},
               attributes: attributes
             ) = assert_receive_span_named("append_to_stream")

      assert error_message =~ "(FunctionClauseError)"

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "append_to_stream",
               "code.function": "append_to_stream",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": stream_uuid,
               "commanded.expected_version": 0,
               "erlang.exception.kind": :error,
               "error.type": "Elixir.FunctionClauseError"
             }

      assert_handler_attached(:append_to_stream)
    end
  end

  defp expected_event_store_destination(application) do
    {_adapter, adapter_meta} = CommandedApplication.event_store_adapter(application)
    destination_name = Map.get(adapter_meta, :name) || Map.get(adapter_meta, :event_store)

    inspect(destination_name)
  end

  defp build_snapshot(source_uuid) do
    %SnapshotData{
      source_uuid: source_uuid,
      source_version: 5,
      source_type: "Elixir.Commanded.TestSupport.TestDomain.Account",
      data: build_account(account_id: source_uuid),
      metadata: %{},
      created_at: DateTime.utc_now()
    }
  end

  defp unique_subscription_name do
    "subscription-#{System.unique_integer([:positive])}"
  end

  defp assert_receive_span_named(name, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    receive_span_named(name, deadline)
  end

  defp receive_span_named(name, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:span, span(name: ^name) = span_record} ->
        span_record

      {:span, _other} ->
        receive_span_named(name, deadline)
    after
      timeout ->
        flunk("Expected span #{inspect(name)}")
    end
  end

  defp assert_exception_event(events, exception_type) do
    events_list = :otel_events.list(events)
    exception_event = Enum.find(events_list, &(elem(&1, 2) == :exception))

    assert exception_event

    {:event, _timestamp, :exception, attrs_tuple} = exception_event
    {:attributes, _, _, _, attrs_map} = attrs_tuple

    assert attrs_map[:"exception.type"] == exception_type
  end

  defp assert_handler_attached(event) do
    handlers = :telemetry.list_handlers([:commanded, :event_store, event, :start])

    assert Enum.any?(handlers, &match?(%{id: {OTelEventStore, ^event}}, &1))
  end

  defp detach_handlers do
    for event <- @events do
      for suffix <- [:start, :stop, :exception] do
        for handler <- :telemetry.list_handlers([:commanded, :event_store, event, suffix]) do
          :telemetry.detach(handler.id)
        end
      end
    end
  end

  defp attach_warning_handler do
    handler_id = {__MODULE__, :warning, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:commanded, :opentelemetry, :warning],
        &__MODULE__.handle_warning/4,
        self()
      )

    handler_id
  end

  def handle_warning(event, measurements, meta, pid) do
    send(pid, {:warning, event, measurements, meta})
  end
end
