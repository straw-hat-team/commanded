defmodule Commanded.Projections.CommandedBatchIntegrationTest do
  use ExUnit.Case

  import Commanded.Projections.ProjectionAssertions
  import Ecto.Query

  alias Commanded.Projections.Events.AnEvent
  alias Commanded.Projections.Projection
  alias Commanded.Projections.Repo
  alias Ecto.Adapters.SQL.Sandbox

  defmodule IntegrationBatchProjector do
    use Commanded.Projections.Ecto,
      application: TestApplication,
      repo: Commanded.Projections.Repo,
      name: "IntegrationBatchProjector",
      batch_size: 5

    project_batch fn events, multi ->
      projections =
        Enum.map(events, fn
          {%Commanded.Projections.Events.AnEvent{name: name}, _metadata} -> %{name: name}
        end)

      Ecto.Multi.insert_all(multi, :projections, Commanded.Projections.Projection, projections)
    end
  end

  setup do
    start_supervised!(TestApplication)
    Sandbox.checkout(Repo)

    :ok
  end

  describe "Commanded batch integration" do
    test "handle_batch function is defined" do
      assert function_exported?(IntegrationBatchProjector, :handle_batch, 1)
    end

    test "handle_batch processes single batch correctly" do
      events = [
        {%AnEvent{name: "e1"}, %{handler_name: "IntegrationBatchProjector", event_number: 1}},
        {%AnEvent{name: "e2"}, %{handler_name: "IntegrationBatchProjector", event_number: 2}},
        {%AnEvent{name: "e3"}, %{handler_name: "IntegrationBatchProjector", event_number: 3}}
      ]

      assert :ok == IntegrationBatchProjector.handle_batch(events)

      assert_projections(Projection, ["e1", "e2", "e3"])

      last_seen =
        Repo.one(
          from(pv in IntegrationBatchProjector.ProjectionVersion,
            where: pv.projection_name == "IntegrationBatchProjector",
            select: pv.last_seen_event_number
          )
        )

      assert last_seen == 3
    end

    test "handle_batch processes multiple batches with correct watermark" do
      assert :ok ==
               IntegrationBatchProjector.handle_batch([
                 {%AnEvent{name: "batch1_e1"},
                  %{handler_name: "IntegrationBatchProjector", event_number: 1}},
                 {%AnEvent{name: "batch1_e2"},
                  %{handler_name: "IntegrationBatchProjector", event_number: 2}}
               ])

      assert :ok ==
               IntegrationBatchProjector.handle_batch([
                 {%AnEvent{name: "batch2_e3"},
                  %{handler_name: "IntegrationBatchProjector", event_number: 3}},
                 {%AnEvent{name: "batch2_e4"},
                  %{handler_name: "IntegrationBatchProjector", event_number: 4}}
               ])

      assert_projections(Projection, ["batch1_e1", "batch1_e2", "batch2_e3", "batch2_e4"])

      last_seen =
        Repo.one(
          from(pv in IntegrationBatchProjector.ProjectionVersion,
            where: pv.projection_name == "IntegrationBatchProjector",
            select: pv.last_seen_event_number
          )
        )

      assert last_seen == 4
    end

    test "handle_batch maintains idempotency across multiple calls" do
      events = [
        {%AnEvent{name: "idem_e1"},
         %{handler_name: "IntegrationBatchProjector", event_number: 10}},
        {%AnEvent{name: "idem_e2"},
         %{handler_name: "IntegrationBatchProjector", event_number: 11}}
      ]

      assert :ok == IntegrationBatchProjector.handle_batch(events)
      assert :ok == IntegrationBatchProjector.handle_batch(events)

      assert_projections(Projection, ["idem_e1", "idem_e2"])

      last_seen =
        Repo.one(
          from(pv in IntegrationBatchProjector.ProjectionVersion,
            where: pv.projection_name == "IntegrationBatchProjector",
            select: pv.last_seen_event_number
          )
        )

      assert last_seen == 11
    end
  end
end
