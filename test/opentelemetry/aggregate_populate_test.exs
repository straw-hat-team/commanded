defmodule Commanded.OpenTelemetry.AggregatePopulateTest do
  @moduledoc """
  Tests for AggregatePopulate OpenTelemetry instrumentation.

  Follows the same patterns as AggregateTest and EventHandlerTest.
  """

  use Commanded.OpenTelemetryCase, async: false

  alias Commanded.OpenTelemetry.AggregatePopulate
  alias Commanded.TestSupport.Factory
  alias Commanded.UUID

  require OpenTelemetry.Tracer, as: Tracer

  setup do
    detach_populate_handlers()
    AggregatePopulate.setup()

    :ok
  end

  describe "setup/0" do
    test "attaches telemetry handlers for aggregate load and populate events" do
      detach_populate_handlers()

      AggregatePopulate.setup()

      for event <- [
            [:commanded, :aggregate, :load, :start],
            [:commanded, :aggregate, :load, :stop],
            [:commanded, :aggregate, :populate, :start],
            [:commanded, :aggregate, :populate, :stop]
          ] do
        handlers = :telemetry.list_handlers(event)

        assert length(handlers) >= 1,
               "Expected handler for event #{inspect(event)}"
      end
    end

    test "calling setup twice raises MatchError (fail fast)" do
      detach_populate_handlers()

      :ok = AggregatePopulate.setup()

      handlers = :telemetry.list_handlers([:commanded, :aggregate, :load, :start])
      assert length(handlers) == 1

      assert_raise MatchError, fn ->
        AggregatePopulate.setup()
      end
    end
  end

  describe "attribute completeness" do
    setup do
      detach_populate_handlers()
      AggregatePopulate.setup()
      :ok
    end

    test "includes ALL required span attributes" do
      aggregate_uuid = UUID.uuid4()

      meta =
        Factory.build_aggregate_populate_metadata(
          aggregate_uuid: aggregate_uuid,
          aggregate_version: 5
        )

      :telemetry.span([:commanded, :aggregate, :populate], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "populate MockAggregate",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      attrs = :otel_attributes.map(attributes)

      assert attrs == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "populate",
               "messaging.destination.name": "MockAggregate",
               "code.function": "populate",
               "code.namespace": "MockAggregate",
               "commanded.application": MockApp,
               "commanded.aggregate.uuid": aggregate_uuid,
               "commanded.aggregate.version": 5,
               "commanded.event.count": 0
             }
    end
  end

  describe "load span (event store latency including stream_not_found)" do
    setup do
      detach_populate_handlers()
      AggregatePopulate.setup()
      :ok
    end

    test "emits load span for stream_not_found (count: 0)" do
      aggregate_uuid = UUID.uuid4()

      meta =
        Factory.build_aggregate_populate_metadata(
          aggregate_uuid: aggregate_uuid,
          aggregate_version: 0
        )

      :telemetry.execute([:commanded, :aggregate, :load, :start], %{}, meta)

      stop_meta =
        Factory.build_aggregate_load_stop_metadata(meta,
          snapshot_used: false,
          snapshot_source_version: nil,
          aggregate_version: 0
        )

      :telemetry.execute([:commanded, :aggregate, :load, :stop], %{count: 0}, stop_meta)

      assert_receive {:span,
                      span(
                        name: "load MockAggregate",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "load",
               "messaging.destination.name": "MockAggregate",
               "code.function": "load",
               "code.namespace": "MockAggregate",
               "commanded.application": MockApp,
               "commanded.aggregate.uuid": aggregate_uuid,
               "commanded.aggregate.version": 0,
               "commanded.event.count": 0,
               "commanded.snapshot.used": false
             }
    end

    test "emits load span with snapshot attributes when snapshot was used" do
      aggregate_uuid = UUID.uuid4()

      meta =
        Factory.build_aggregate_populate_metadata(
          aggregate_uuid: aggregate_uuid,
          aggregate_version: 5
        )

      :telemetry.execute([:commanded, :aggregate, :load, :start], %{}, meta)

      stop_meta =
        Factory.build_aggregate_load_stop_metadata(meta,
          snapshot_used: true,
          snapshot_source_version: 5,
          aggregate_version: 5
        )

      :telemetry.execute([:commanded, :aggregate, :load, :stop], %{count: 0}, stop_meta)

      assert_receive {:span,
                      span(
                        name: "load MockAggregate",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      attrs = :otel_attributes.map(attributes)

      assert attrs[:"commanded.snapshot.used"] == true
      assert attrs[:"commanded.snapshot.source_version"] == 5
    end
  end

  describe "edge cases" do
    setup do
      detach_populate_handlers()
      AggregatePopulate.setup()
      :ok
    end

    test "handles zero events populated" do
      aggregate_uuid = UUID.uuid4()

      meta =
        Factory.build_aggregate_populate_metadata(
          aggregate_uuid: aggregate_uuid,
          aggregate_version: 0
        )

      :telemetry.execute([:commanded, :aggregate, :populate, :start], %{}, meta)
      :telemetry.execute([:commanded, :aggregate, :populate, :stop], %{count: 0}, meta)

      assert_receive {:span,
                      span(
                        name: "populate MockAggregate",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "populate",
               "messaging.destination.name": "MockAggregate",
               "code.function": "populate",
               "code.namespace": "MockAggregate",
               "commanded.application": MockApp,
               "commanded.aggregate.uuid": aggregate_uuid,
               "commanded.aggregate.version": 0,
               "commanded.event.count": 0
             }
    end

    test "handles multiple events populated" do
      aggregate_uuid = UUID.uuid4()

      meta =
        Factory.build_aggregate_populate_metadata(
          aggregate_uuid: aggregate_uuid,
          aggregate_version: 0
        )

      :telemetry.execute([:commanded, :aggregate, :populate, :start], %{}, meta)

      stop_meta = Map.put(meta, :aggregate_version, 10)
      :telemetry.execute([:commanded, :aggregate, :populate, :stop], %{count: 10}, stop_meta)

      assert_receive {:span,
                      span(
                        name: "populate MockAggregate",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "populate",
               "messaging.destination.name": "MockAggregate",
               "code.function": "populate",
               "code.namespace": "MockAggregate",
               "commanded.application": MockApp,
               "commanded.aggregate.uuid": aggregate_uuid,
               "commanded.aggregate.version": 10,
               "commanded.event.count": 10
             }
    end
  end

  describe "trace context propagation" do
    setup do
      detach_populate_handlers()
      AggregatePopulate.setup()
      :ok
    end

    test "load span becomes child of caller when traceparent is in metadata" do
      {parent_trace_id, parent_span_id, traceparent} =
        Tracer.with_span "parent.command.dispatch" do
          ctx = Tracer.current_span_ctx()

          {
            :otel_span.trace_id(ctx),
            :otel_span.span_id(ctx),
            encode_traceparent(ctx)
          }
        end

      meta =
        Factory.build_aggregate_populate_metadata(metadata: %{"traceparent" => traceparent})

      :telemetry.execute([:commanded, :aggregate, :load, :start], %{}, meta)

      stop_meta =
        Factory.build_aggregate_load_stop_metadata(meta,
          snapshot_used: false,
          aggregate_version: 0
        )

      :telemetry.execute([:commanded, :aggregate, :load, :stop], %{count: 0}, stop_meta)

      assert_receive {:span,
                      span(
                        name: "load MockAggregate",
                        trace_id: child_trace_id,
                        parent_span_id: received_parent_span_id
                      )},
                     1000

      assert child_trace_id == parent_trace_id
      assert received_parent_span_id == parent_span_id
    end

    test "load span is independent when no traceparent in metadata" do
      meta = Factory.build_aggregate_populate_metadata(metadata: %{})

      :telemetry.execute([:commanded, :aggregate, :load, :start], %{}, meta)

      stop_meta =
        Factory.build_aggregate_load_stop_metadata(meta,
          snapshot_used: false,
          aggregate_version: 0
        )

      :telemetry.execute([:commanded, :aggregate, :load, :stop], %{count: 0}, stop_meta)

      assert_receive {:span,
                      span(
                        name: "load MockAggregate",
                        parent_span_id: :undefined
                      )},
                     1000
    end

    test "load span is independent when traceparent is invalid" do
      meta =
        Factory.build_aggregate_populate_metadata(metadata: %{"traceparent" => "invalid-format"})

      :telemetry.execute([:commanded, :aggregate, :load, :start], %{}, meta)

      stop_meta =
        Factory.build_aggregate_load_stop_metadata(meta,
          snapshot_used: false,
          aggregate_version: 0
        )

      :telemetry.execute([:commanded, :aggregate, :load, :stop], %{count: 0}, stop_meta)

      assert_receive {:span,
                      span(
                        name: "load MockAggregate",
                        parent_span_id: :undefined
                      )},
                     1000
    end

    test "load span is independent when metadata key is nil" do
      meta =
        Factory.build_aggregate_populate_metadata()
        |> Map.put(:metadata, nil)

      :telemetry.execute([:commanded, :aggregate, :load, :start], %{}, meta)

      stop_meta =
        Factory.build_aggregate_load_stop_metadata(meta,
          snapshot_used: false,
          aggregate_version: 0
        )

      :telemetry.execute([:commanded, :aggregate, :load, :stop], %{count: 0}, stop_meta)

      assert_receive {:span,
                      span(
                        name: "load MockAggregate",
                        parent_span_id: :undefined
                      )},
                     1000
    end
  end

  defp encode_traceparent(span_ctx) do
    trace_id = :otel_span.trace_id(span_ctx)
    span_id = :otel_span.span_id(span_ctx)
    trace_flags = span_ctx(span_ctx, :trace_flags)

    hex_trace_id = :io_lib.format("~32.16.0b", [trace_id]) |> IO.iodata_to_binary()
    hex_span_id = :io_lib.format("~16.16.0b", [span_id]) |> IO.iodata_to_binary()
    hex_flags = :io_lib.format("~2.16.0b", [trace_flags]) |> IO.iodata_to_binary()

    "00-#{hex_trace_id}-#{hex_span_id}-#{hex_flags}"
  end

  defp detach_populate_handlers do
    for event <- [
          [:commanded, :aggregate, :load, :start],
          [:commanded, :aggregate, :load, :stop],
          [:commanded, :aggregate, :populate, :start],
          [:commanded, :aggregate, :populate, :stop]
        ] do
      for handler <- :telemetry.list_handlers(event) do
        :telemetry.detach(handler.id)
      end
    end
  end
end
