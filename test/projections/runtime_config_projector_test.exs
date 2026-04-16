defmodule Commanded.Projections.RuntimeConfigProjectorTest do
  use Commanded.MockProjectionCase

  alias Commanded.Projections.Events.AnEvent
  alias Commanded.Projections.{Projection, ProjectionAssertions, Repo, RuntimeConfigProjector}
  alias Commanded.TestSupport.Factory
  alias Ecto.Adapters.SQL.Sandbox

  import ProjectionAssertions

  describe "runtime config projector" do
    setup do
      projector1 =
        start_supervised!(
          {RuntimeConfigProjector, application: TestApplication, name: "RuntimeProjector1"}
        )

      projector2 =
        start_supervised!(
          {RuntimeConfigProjector, application: TestApplication, name: "RuntimeProjector2"}
        )

      Sandbox.allow(Repo, self(), projector1)
      Sandbox.allow(Repo, self(), projector2)

      [projector1: projector1, projector2: projector2]
    end

    test "should handle a projected event", %{projector1: projector1} do
      send_events(projector1, [
        Factory.build_recorded_event(
          data: %AnEvent{pid: self()},
          event_number: 1,
          stream_version: 1
        )
      ])

      assert_receive {:project, "AnEvent"}
      assert_receive {:projected, "AnEvent"}

      assert_projections(Projection, ["AnEvent"])
      assert last_seen_event("RuntimeProjector1") == 1
      assert last_seen_event("RuntimeProjector2") == nil
    end
  end

  defp send_events(projector, events) do
    send(projector, {:events, events})
  end
end
