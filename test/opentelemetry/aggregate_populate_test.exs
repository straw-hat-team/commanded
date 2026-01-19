defmodule Commanded.OpenTelemetry.AggregatePopulateTest do
  @moduledoc """
  Tests for AggregatePopulate OpenTelemetry instrumentation.

  Follows the same patterns as AggregateTest and EventHandlerTest.
  """

  use Commanded.OpenTelemetryCase, async: false

  alias Commanded.OpenTelemetry.AggregatePopulate
  alias Commanded.TestSupport.Factory
  alias Commanded.UUID

  setup do
    detach_populate_handlers()
    AggregatePopulate.setup()

    :ok
  end

  describe "setup/0" do
    test "attaches telemetry handlers for aggregate populate events" do
      detach_populate_handlers()

      AggregatePopulate.setup()

      for event <- [
            [:commanded, :aggregate, :populate, :start],
            [:commanded, :aggregate, :populate, :stop]
          ] do
        handlers = :telemetry.list_handlers(event)

        assert Enum.any?(
                 handlers,
                 &match?(%{id: {AggregatePopulate, :populate}}, &1)
               ),
               "Expected handler for event #{inspect(event)}"
      end
    end

    test "calling setup twice raises MatchError (fail fast)" do
      detach_populate_handlers()

      :ok = AggregatePopulate.setup()

      handlers = :telemetry.list_handlers([:commanded, :aggregate, :populate, :start])
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
                        name: "commanded.aggregate.populate",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      attrs = :otel_attributes.map(attributes)

      assert attrs == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "populate",
               "code.function": "populate",
               "commanded.application": MockApp,
               "commanded.aggregate.uuid": aggregate_uuid,
               "commanded.aggregate.version": 5,
               "commanded.event.count": 0
             }
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
                        name: "commanded.aggregate.populate",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "populate",
               "code.function": "populate",
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
                        name: "commanded.aggregate.populate",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "populate",
               "code.function": "populate",
               "commanded.application": MockApp,
               "commanded.aggregate.uuid": aggregate_uuid,
               "commanded.aggregate.version": 10,
               "commanded.event.count": 10
             }
    end
  end

  defp detach_populate_handlers do
    for event <- [
          [:commanded, :aggregate, :populate, :start],
          [:commanded, :aggregate, :populate, :stop]
        ] do
      for handler <- :telemetry.list_handlers(event) do
        :telemetry.detach(handler.id)
      end
    end
  end
end
