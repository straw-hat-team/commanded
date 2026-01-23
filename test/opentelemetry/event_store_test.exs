defmodule Commanded.OpenTelemetry.EventStoreTest do
  @moduledoc """
  Tests for EventStore OpenTelemetry instrumentation.

  Follows the same patterns as ApplicationTest, AggregateTest, etc.
  """

  use Commanded.OpenTelemetryCase, async: false

  import Commanded.TestSupport.Factory

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

  describe "append_to_stream spans" do
    setup do
      detach_handlers()
      OTelEventStore.setup()
      :ok
    end

    test "creates span with correct attributes" do
      stream_uuid = UUID.uuid4()

      meta =
        build_event_store_append_to_stream_metadata(
          application: TestApp,
          stream_uuid: stream_uuid,
          expected_version: 0
        )

      :telemetry.span([:commanded, :event_store, :append_to_stream], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "append_to_stream TestApp",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "append_to_stream",
               "code.function": "append_to_stream",
               "commanded.application": TestApp,
               "commanded.stream.uuid": stream_uuid,
               "commanded.expected_version": 0
             }
    end
  end

  describe "stream_forward spans" do
    setup do
      detach_handlers()
      OTelEventStore.setup()
      :ok
    end

    test "creates span with correct attributes" do
      stream_uuid = UUID.uuid4()

      meta =
        build_event_store_stream_forward_metadata(
          application: TestApp,
          stream_uuid: stream_uuid,
          start_version: 0,
          read_batch_size: 1000
        )

      :telemetry.span([:commanded, :event_store, :stream_forward], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "stream_forward TestApp",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "stream_forward",
               "code.function": "stream_forward",
               "commanded.application": TestApp,
               "commanded.stream.uuid": stream_uuid
             }
    end
  end

  describe "subscribe_to spans" do
    setup do
      detach_handlers()
      OTelEventStore.setup()
      :ok
    end

    test "creates span with subscription attributes" do
      meta =
        build_event_store_subscribe_to_metadata(
          application: TestApp,
          stream_uuid: :all,
          subscription_name: "TestSubscription",
          subscriber: self(),
          start_from: :origin
        )

      :telemetry.span([:commanded, :event_store, :subscribe_to], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "subscribe_to TestApp",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "subscribe_to",
               "messaging.destination.subscription.name": "TestSubscription",
               "code.function": "subscribe_to",
               "commanded.application": TestApp,
               "commanded.stream.uuid": :all,
               "commanded.subscription.name": "TestSubscription",
               "commanded.start_from": "origin"
             }
    end
  end

  describe "ack_event spans" do
    setup do
      detach_handlers()
      OTelEventStore.setup()
      :ok
    end

    test "creates span with settle operation type" do
      meta =
        build_event_store_ack_event_metadata(
          application: TestApp,
          subscription: self(),
          event: %{}
        )

      :telemetry.span([:commanded, :event_store, :ack_event], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "ack_event TestApp",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :settle,
               "messaging.operation.name": "ack_event",
               "code.function": "ack_event",
               "commanded.application": TestApp
             }
    end
  end

  describe "error handling" do
    setup do
      detach_handlers()
      OTelEventStore.setup()
      :ok
    end

    test "sets error status when stop includes error" do
      stream_uuid = UUID.uuid4()

      meta =
        build_event_store_append_to_stream_metadata(
          application: TestApp,
          stream_uuid: stream_uuid,
          expected_version: 0
        )

      :telemetry.execute([:commanded, :event_store, :append_to_stream, :start], %{}, meta)

      stop_meta = Map.put(meta, :error, :stream_not_found)

      :telemetry.execute(
        [:commanded, :event_store, :append_to_stream, :stop],
        %{duration: 1000},
        stop_meta
      )

      assert_receive {:span,
                      span(
                        name: "append_to_stream TestApp",
                        status: {:status, :error, error_message},
                        attributes: span_attrs
                      )},
                     1000

      assert error_message == ":stream_not_found"

      assert :otel_attributes.map(span_attrs) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "append_to_stream",
               "code.function": "append_to_stream",
               "commanded.application": TestApp,
               "commanded.stream.uuid": stream_uuid,
               "commanded.expected_version": 0,
               "error.type": "stream_not_found"
             }
    end

    test "handles RuntimeError exception" do
      stream_uuid = UUID.uuid4()

      meta =
        build_event_store_append_to_stream_metadata(
          application: TestApp,
          stream_uuid: stream_uuid,
          expected_version: 0
        )

      :telemetry.execute([:commanded, :event_store, :append_to_stream, :start], %{}, meta)

      exception_meta =
        Map.merge(meta, %{
          kind: :error,
          reason: %RuntimeError{message: "connection failed"},
          stacktrace: []
        })

      :telemetry.execute(
        [:commanded, :event_store, :append_to_stream, :exception],
        %{duration: 100},
        exception_meta
      )

      assert_receive {:span,
                      span(
                        name: "append_to_stream TestApp",
                        status: {:status, :error, error_msg},
                        attributes: span_attrs
                      )},
                     1000

      assert error_msg == "** (RuntimeError) connection failed"

      assert :otel_attributes.map(span_attrs) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "append_to_stream",
               "code.function": "append_to_stream",
               "commanded.application": TestApp,
               "commanded.stream.uuid": stream_uuid,
               "commanded.expected_version": 0,
               "erlang.exception.kind": :error,
               "error.type": "Elixir.RuntimeError"
             }
    end

    test "records exception event with proper attributes" do
      stream_uuid = UUID.uuid4()

      meta =
        build_event_store_append_to_stream_metadata(
          application: TestApp,
          stream_uuid: stream_uuid,
          expected_version: 0
        )

      :telemetry.execute([:commanded, :event_store, :append_to_stream, :start], %{}, meta)

      exception_meta =
        Map.merge(meta, %{
          kind: :error,
          reason: %RuntimeError{message: "failed"},
          stacktrace: []
        })

      :telemetry.execute(
        [:commanded, :event_store, :append_to_stream, :exception],
        %{duration: 100},
        exception_meta
      )

      assert_receive {:span,
                      span(
                        name: "append_to_stream TestApp",
                        events: events
                      )},
                     1000

      events_list = :otel_events.list(events)
      exception_event = Enum.find(events_list, fn event -> elem(event, 2) == :exception end)
      {:event, _timestamp, :exception, attrs_tuple} = exception_event
      {:attributes, _, _, _, attrs_map} = attrs_tuple

      assert attrs_map[:"exception.type"] == "Elixir.RuntimeError"
      assert attrs_map[:"exception.message"] == "failed"
    end
  end

  describe "record_snapshot spans" do
    setup do
      detach_handlers()
      OTelEventStore.setup()
      :ok
    end

    test "creates span with correct attributes including source_uuid" do
      source_uuid = UUID.uuid4()

      meta =
        build_event_store_record_snapshot_metadata(
          application: TestApp,
          source_uuid: source_uuid
        )

      :telemetry.span([:commanded, :event_store, :record_snapshot], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "record_snapshot TestApp",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "record_snapshot",
               "code.function": "record_snapshot",
               "commanded.application": TestApp,
               "commanded.source.uuid": source_uuid
             }
    end
  end

  describe "read_snapshot spans" do
    setup do
      detach_handlers()
      OTelEventStore.setup()
      :ok
    end

    test "creates span with correct attributes including source_uuid" do
      source_uuid = UUID.uuid4()

      meta =
        build_event_store_read_snapshot_metadata(
          application: TestApp,
          source_uuid: source_uuid
        )

      :telemetry.span([:commanded, :event_store, :read_snapshot], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "read_snapshot TestApp",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "read_snapshot",
               "code.function": "read_snapshot",
               "commanded.application": TestApp,
               "commanded.source.uuid": source_uuid
             }
    end
  end

  describe "delete_snapshot spans" do
    setup do
      detach_handlers()
      OTelEventStore.setup()
      :ok
    end

    test "creates span with correct attributes including source_uuid" do
      source_uuid = UUID.uuid4()

      meta =
        build_event_store_delete_snapshot_metadata(
          application: TestApp,
          source_uuid: source_uuid
        )

      :telemetry.span([:commanded, :event_store, :delete_snapshot], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "delete_snapshot TestApp",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.name": "delete_snapshot",
               "code.function": "delete_snapshot",
               "commanded.application": TestApp,
               "commanded.source.uuid": source_uuid
             }
    end
  end

  describe "subscribe spans" do
    setup do
      detach_handlers()
      OTelEventStore.setup()
      :ok
    end

    test "creates span with correct attributes including stream_uuid" do
      stream_uuid = UUID.uuid4()

      meta =
        build_event_store_subscribe_metadata(
          application: TestApp,
          stream_uuid: stream_uuid
        )

      :telemetry.span([:commanded, :event_store, :subscribe], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "subscribe TestApp",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "subscribe",
               "code.function": "subscribe",
               "commanded.application": TestApp,
               "commanded.stream.uuid": stream_uuid
             }
    end
  end

  describe "unsubscribe spans" do
    setup do
      detach_handlers()
      OTelEventStore.setup()
      :ok
    end

    test "creates span with correct attributes" do
      meta =
        build_event_store_unsubscribe_metadata(
          application: TestApp,
          subscription: self()
        )

      :telemetry.span([:commanded, :event_store, :unsubscribe], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "unsubscribe TestApp",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.name": "unsubscribe",
               "code.function": "unsubscribe",
               "commanded.application": TestApp
             }
    end
  end

  describe "operations without stream_uuid" do
    setup do
      detach_handlers()
      OTelEventStore.setup()
      :ok
    end

    test "creates span name without stream_uuid suffix" do
      meta = build_event_store_delete_subscription_metadata(application: TestApp)

      :telemetry.span([:commanded, :event_store, :delete_subscription], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "delete_subscription TestApp",
                        kind: :internal
                      )},
                     1000
    end
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
end
