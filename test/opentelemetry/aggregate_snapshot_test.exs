defmodule Commanded.OpenTelemetry.AggregateSnapshotTest do
  @moduledoc """
  Tests for AggregateSnapshot OpenTelemetry instrumentation.
  """

  use Commanded.OpenTelemetryCase, async: false

  alias Commanded.OpenTelemetry.AggregateSnapshot
  alias Commanded.TestSupport.Factory
  alias Commanded.UUID

  setup do
    detach_snapshot_handlers()
    AggregateSnapshot.setup()

    :ok
  end

  describe "setup/0" do
    test "attaches telemetry handlers for aggregate snapshot events" do
      detach_snapshot_handlers()

      AggregateSnapshot.setup()

      for event <- [
            [:commanded, :aggregate, :snapshot, :start],
            [:commanded, :aggregate, :snapshot, :stop],
            [:commanded, :aggregate, :snapshot, :exception]
          ] do
        handlers = :telemetry.list_handlers(event)

        assert length(handlers) >= 1,
               "Expected handler for event #{inspect(event)}"
      end
    end

    test "calling setup twice raises MatchError (fail fast)" do
      detach_snapshot_handlers()

      :ok = AggregateSnapshot.setup()

      handlers = :telemetry.list_handlers([:commanded, :aggregate, :snapshot, :start])
      assert length(handlers) == 1

      assert_raise MatchError, fn ->
        AggregateSnapshot.setup()
      end
    end
  end

  describe "snapshot spans" do
    setup do
      detach_snapshot_handlers()
      AggregateSnapshot.setup()
      :ok
    end

    test "creates span with correct attributes" do
      aggregate_uuid = UUID.uuid4()

      meta =
        Factory.build_aggregate_snapshot_metadata(
          aggregate_uuid: aggregate_uuid,
          aggregate_version: 10,
          snapshot_every: 5,
          snapshot_module_version: 1
        )

      :telemetry.span([:commanded, :aggregate, :snapshot], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "snapshot MockAggregate",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :publish,
               "messaging.operation.name": "snapshot",
               "messaging.destination.name": "MockAggregate",
               "code.function": "snapshot",
               "code.namespace": "MockAggregate",
               "commanded.application": MockApp,
               "commanded.aggregate.uuid": aggregate_uuid,
               "commanded.aggregate.version": 10,
               "commanded.snapshot.every": 5,
               "commanded.snapshot.module_version": 1
             }
    end

    test "creates span without optional snapshot attributes when nil" do
      aggregate_uuid = UUID.uuid4()

      meta =
        Factory.build_aggregate_snapshot_metadata(
          aggregate_uuid: aggregate_uuid,
          aggregate_version: 10,
          snapshot_every: nil,
          snapshot_module_version: nil
        )

      :telemetry.span([:commanded, :aggregate, :snapshot], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "snapshot MockAggregate",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      attrs = :otel_attributes.map(attributes)

      refute Map.has_key?(attrs, :"commanded.snapshot.every")
      refute Map.has_key?(attrs, :"commanded.snapshot.module_version")
      assert attrs[:"commanded.aggregate.uuid"] == aggregate_uuid
      assert attrs[:"commanded.aggregate.version"] == 10
    end

    test "sets error status when stop includes error" do
      aggregate_uuid = UUID.uuid4()

      meta =
        Factory.build_aggregate_snapshot_metadata(
          aggregate_uuid: aggregate_uuid,
          aggregate_version: 10
        )

      :telemetry.execute([:commanded, :aggregate, :snapshot, :start], %{}, meta)

      stop_meta = Map.put(meta, :error, :snapshotting_not_configured)

      :telemetry.execute(
        [:commanded, :aggregate, :snapshot, :stop],
        %{duration: 1000},
        stop_meta
      )

      assert_receive {:span,
                      span(
                        name: "snapshot MockAggregate",
                        status: {:status, :error, _error_message},
                        attributes: span_attrs
                      )},
                     1000

      assert :otel_attributes.map(span_attrs)[:"error.type"] == ":snapshotting_not_configured"
    end
  end

  defp detach_snapshot_handlers do
    for event <- [
          [:commanded, :aggregate, :snapshot, :start],
          [:commanded, :aggregate, :snapshot, :stop],
          [:commanded, :aggregate, :snapshot, :exception]
        ] do
      for handler <- :telemetry.list_handlers(event) do
        :telemetry.detach(handler.id)
      end
    end
  end
end
