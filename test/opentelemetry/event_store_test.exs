defmodule Commanded.OpenTelemetry.EventStoreTest do
  @moduledoc """
  Tests for EventStore OpenTelemetry instrumentation.

  Follows the same patterns as ApplicationTest, AggregateTest, etc.
  """

  use Commanded.OpenTelemetryCase, async: false

  import Commanded.TestSupport.Factory

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

      [application_name: inspect(DefaultApp)]
    end

    test "append_to_stream uses the started application in the span name", %{
      application_name: application_name
    } do
      stream_uuid = UUID.uuid4()

      assert :ok = EventStore.append_to_stream(DefaultApp, stream_uuid, 0, [%EventData{}])

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("append_to_stream #{application_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "append_to_stream",
               "code.function": "append_to_stream",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": stream_uuid,
               "commanded.expected_version": 0
             }
    end

    test "stream_forward uses the started application in the span name", %{
      application_name: application_name
    } do
      stream_uuid = UUID.uuid4()

      assert :ok = EventStore.append_to_stream(DefaultApp, stream_uuid, 0, [%EventData{}])
      _ = assert_receive_span_named("append_to_stream #{application_name}")

      assert [_event] = EventStore.stream_forward(DefaultApp, stream_uuid, 0)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("stream_forward #{application_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "stream_forward",
               "code.function": "stream_forward",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": stream_uuid
             }
    end

    test "subscribe_to uses the started application in the span name", %{
      application_name: application_name
    } do
      subscription_name = unique_subscription_name()

      assert {:ok, subscription} =
               EventStore.subscribe_to(DefaultApp, :all, subscription_name, self(), :origin)

      assert_receive {:subscribed, ^subscription}, 1000

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("subscribe_to #{application_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "subscribe_to",
               "messaging.destination.subscription.name": subscription_name,
               "code.function": "subscribe_to",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": :all,
               "commanded.subscription.name": subscription_name,
               "commanded.start_from": "origin"
             }
    end

    test "ack_event uses the started application in the span name", %{
      application_name: application_name
    } do
      subscription_name = unique_subscription_name()
      stream_uuid = UUID.uuid4()

      assert {:ok, subscription} =
               EventStore.subscribe_to(DefaultApp, :all, subscription_name, self(), :origin)

      assert_receive {:subscribed, ^subscription}, 1000
      _ = assert_receive_span_named("subscribe_to #{application_name}")

      assert :ok = EventStore.append_to_stream(DefaultApp, stream_uuid, 0, [%EventData{}])
      assert_receive {:events, [event]}, 1000
      _ = assert_receive_span_named("append_to_stream #{application_name}")

      assert :ok = EventStore.ack_event(DefaultApp, subscription, event)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("ack_event #{application_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :settle,
               "messaging.operation.name": "ack_event",
               "code.function": "ack_event",
               "commanded.application": DefaultApp
             }
    end

    test "record_snapshot uses the started application in the span name", %{
      application_name: application_name
    } do
      source_uuid = UUID.uuid4()
      snapshot = build_snapshot(source_uuid)

      assert :ok = EventStore.record_snapshot(DefaultApp, snapshot)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("record_snapshot #{application_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "record_snapshot",
               "code.function": "record_snapshot",
               "commanded.application": DefaultApp,
               "commanded.source.uuid": source_uuid
             }
    end

    test "read_snapshot uses the started application in the span name", %{
      application_name: application_name
    } do
      source_uuid = UUID.uuid4()
      snapshot = build_snapshot(source_uuid)

      assert :ok = EventStore.record_snapshot(DefaultApp, snapshot)
      _ = assert_receive_span_named("record_snapshot #{application_name}")

      assert {:ok, %SnapshotData{source_uuid: ^source_uuid}} =
               EventStore.read_snapshot(DefaultApp, source_uuid)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("read_snapshot #{application_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "read_snapshot",
               "code.function": "read_snapshot",
               "commanded.application": DefaultApp,
               "commanded.source.uuid": source_uuid
             }
    end

    test "delete_snapshot uses the started application in the span name", %{
      application_name: application_name
    } do
      source_uuid = UUID.uuid4()
      snapshot = build_snapshot(source_uuid)

      assert :ok = EventStore.record_snapshot(DefaultApp, snapshot)
      _ = assert_receive_span_named("record_snapshot #{application_name}")

      assert :ok = EventStore.delete_snapshot(DefaultApp, source_uuid)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("delete_snapshot #{application_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.name": "delete_snapshot",
               "code.function": "delete_snapshot",
               "commanded.application": DefaultApp,
               "commanded.source.uuid": source_uuid
             }
    end

    test "subscribe uses the started application in the span name", %{
      application_name: application_name
    } do
      stream_uuid = UUID.uuid4()

      assert :ok = EventStore.subscribe(DefaultApp, stream_uuid)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("subscribe #{application_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "subscribe",
               "code.function": "subscribe",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": stream_uuid
             }
    end

    test "unsubscribe uses the started application in the span name", %{
      application_name: application_name
    } do
      subscription_name = unique_subscription_name()

      assert {:ok, subscription} =
               EventStore.subscribe_to(DefaultApp, :all, subscription_name, self(), :origin)

      assert_receive {:subscribed, ^subscription}, 1000
      _ = assert_receive_span_named("subscribe_to #{application_name}")

      assert :ok = EventStore.unsubscribe(DefaultApp, subscription)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("unsubscribe #{application_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.name": "unsubscribe",
               "code.function": "unsubscribe",
               "commanded.application": DefaultApp
             }
    end

    test "delete_subscription uses the started application in the span name", %{
      application_name: application_name
    } do
      subscription_name = unique_subscription_name()

      assert {:ok, subscription} =
               EventStore.subscribe_to(DefaultApp, :all, subscription_name, self(), :origin)

      assert_receive {:subscribed, ^subscription}, 1000
      _ = assert_receive_span_named("subscribe_to #{application_name}")

      assert :ok = EventStore.unsubscribe(DefaultApp, subscription)
      _ = assert_receive_span_named("unsubscribe #{application_name}")

      assert :ok = EventStore.delete_subscription(DefaultApp, :all, subscription_name)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("delete_subscription #{application_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.name": "delete_subscription",
               "code.function": "delete_subscription",
               "commanded.application": DefaultApp
             }
    end

    test "missing streams still emit spans for the started application", %{
      application_name: application_name
    } do
      stream_uuid = UUID.uuid4()

      assert {:error, :stream_not_found} = EventStore.stream_forward(DefaultApp, stream_uuid)

      assert span(kind: :internal, attributes: attributes) =
               assert_receive_span_named("stream_forward #{application_name}")

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "stream_forward",
               "code.function": "stream_forward",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": stream_uuid
             }
    end
  end

  describe "synthetic coverage for internal branches" do
    test "stop events set error status when metadata includes error" do
      stream_uuid = UUID.uuid4()
      application_name = inspect(DefaultApp)
      span_name = "append_to_stream #{application_name}"

      meta =
        build_event_store_append_to_stream_metadata(
          application: DefaultApp,
          stream_uuid: stream_uuid,
          expected_version: 0
        )

      :telemetry.execute([:commanded, :event_store, :append_to_stream, :start], %{}, meta)

      :telemetry.execute(
        [:commanded, :event_store, :append_to_stream, :stop],
        %{duration: 1000},
        Map.put(meta, :error, :stream_not_found)
      )

      assert span(
               name: ^span_name,
               status: {:status, :error, error_message},
               attributes: attributes
             ) = assert_receive_span_named(span_name)

      assert error_message == ":stream_not_found"

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "append_to_stream",
               "code.function": "append_to_stream",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": stream_uuid,
               "commanded.expected_version": 0,
               "error.type": "stream_not_found"
             }
    end

    test "exception events keep exception type and message attributes" do
      stream_uuid = UUID.uuid4()
      application_name = inspect(DefaultApp)
      span_name = "append_to_stream #{application_name}"

      meta =
        build_event_store_append_to_stream_metadata(
          application: DefaultApp,
          stream_uuid: stream_uuid,
          expected_version: 0
        )

      :telemetry.execute([:commanded, :event_store, :append_to_stream, :start], %{}, meta)

      :telemetry.execute(
        [:commanded, :event_store, :append_to_stream, :exception],
        %{duration: 100},
        Map.merge(meta, %{
          kind: :error,
          reason: %RuntimeError{message: "failed"},
          stacktrace: []
        })
      )

      assert span(
               name: ^span_name,
               status: {:status, :error, error_message},
               attributes: attributes,
               events: events
             ) = assert_receive_span_named(span_name)

      assert error_message == "** (RuntimeError) failed"

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "append_to_stream",
               "code.function": "append_to_stream",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": stream_uuid,
               "commanded.expected_version": 0,
               "erlang.exception.kind": :error,
               "error.type": "Elixir.RuntimeError"
             }

      assert_exception_event(events, "Elixir.RuntimeError", "failed")
    end
  end

  describe "exception spans" do
    test "unstarted applications emit exception spans without detaching the handler" do
      stream_uuid = UUID.uuid4()
      application_name = inspect(DefaultApp)
      span_name = "append_to_stream #{application_name}"

      assert_raise RuntimeError, fn ->
        EventStore.append_to_stream(DefaultApp, stream_uuid, 0, [%EventData{}])
      end

      assert span(
               name: ^span_name,
               status: {:status, :error, error_message},
               attributes: attributes,
               events: events
             ) = assert_receive_span_named(span_name)

      assert error_message =~ "could not lookup #{application_name}"

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "append_to_stream",
               "code.function": "append_to_stream",
               "commanded.application": DefaultApp,
               "commanded.stream.uuid": stream_uuid,
               "commanded.expected_version": 0,
               "erlang.exception.kind": :error,
               "error.type": "Elixir.RuntimeError"
             }

      assert_exception_event(events, "Elixir.RuntimeError")
      assert_handler_attached(:append_to_stream)
    end
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

  defp assert_exception_event(events, exception_type, exception_message \\ nil) do
    events_list = :otel_events.list(events)
    exception_event = Enum.find(events_list, fn event(name: name) -> name == :exception end)

    assert exception_event

    event(attributes: exc_attrs) = exception_event
    attrs_map = :otel_attributes.map(exc_attrs)

    assert attrs_map[:"exception.type"] == exception_type

    if exception_message do
      assert attrs_map[:"exception.message"] == exception_message
    end
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
end
