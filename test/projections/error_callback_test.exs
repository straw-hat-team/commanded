defmodule Commanded.Projections.ErrorCallbackTest do
  use Commanded.MockProjectionCase

  import Commanded.Projections.ProjectionAssertions
  import ExUnit.CaptureLog

  alias Commanded.Projections.Events.{
    AnEvent,
    ErrorEvent,
    ExceptionEvent,
    InvalidMultiEvent,
    RaiseEvent
  }

  alias Commanded.Projections.Projection
  alias Commanded.Projections.Repo
  alias Commanded.TestSupport.Factory
  alias Ecto.Adapters.SQL.Sandbox

  describe "error handling" do
    setup [:start_projector]

    test "should allow returning an error tagged tuple from `project` macro", %{
      projector: projector
    } do
      event = %ErrorEvent{pid: self()}
      metadata = %{handler_name: "ErrorProjector", event_number: 1}

      events = [build_projection_event(event, 1, metadata)]

      send(projector, {:events, events})

      assert_receive {:error, :failed}
    end

    test "should rescue exceptions in `project` macro", %{projector: projector} do
      event = %RaiseEvent{pid: self(), message: "it crashed, it crashed, it crashed"}
      metadata = %{event_number: 1}

      events = [build_projection_event(event, 1, metadata)]

      log =
        capture_log(fn ->
          send(projector, {:events, events})

          assert_receive {:error, %RuntimeError{message: "it crashed, it crashed, it crashed"}}
        end)

      assert log =~ "** (RuntimeError) it crashed, it crashed, it crashed"

      assert log =~
               "test/support/error_projector.ex:37: anonymous fn/2 in ErrorProjector.handle/2"
    end
  end

  describe "`error/3` callback function" do
    setup [:start_projector]

    test "should be called on error", %{projector: projector} do
      event = %ErrorEvent{pid: self()}
      metadata = %{event_number: 1}

      events = [build_projection_event(event, 1, metadata)]

      send(projector, {:events, events})

      assert_receive {:error, :failed}
      assert Process.alive?(projector)
    end

    test "should be called on exception", %{projector: projector} do
      event = %ExceptionEvent{pid: self()}
      metadata = %{event_number: 1}

      events = [build_projection_event(event, 1, metadata)]

      send(projector, {:events, events})

      assert_receive {:error, %Ecto.ChangeError{}}
      assert Process.alive?(projector)
    end

    test "should be called on invalid `Ecto.Multi`", %{projector: projector} do
      event = %InvalidMultiEvent{pid: self()}
      metadata = %{event_number: 1}

      events = [build_projection_event(event, 1, metadata)]

      send(projector, {:events, events})

      assert_receive {:error, %ArgumentError{}}
      assert Process.alive?(projector)
    end

    test "should continue on error after skipping problematic events", %{projector: projector} do
      events = [
        build_projection_event(%ErrorEvent{pid: self()}, 1, %{event_number: 1}),
        build_projection_event(%ExceptionEvent{pid: self()}, 2, %{event_number: 2}),
        build_projection_event(%AnEvent{pid: self()}, 3, %{event_number: 3})
      ]

      send(projector, {:events, events})

      assert_receive {:error, :failed}
      assert_receive {:error, %Ecto.ChangeError{}}
      assert_receive %AnEvent{}

      assert Process.alive?(projector)
      assert_projections(Projection, ["AnEvent"])
      assert_seen_event("ErrorProjector", 3)
    end
  end

  defp start_projector(_context) do
    projector = start_supervised!(ErrorProjector)

    Sandbox.allow(Repo, self(), projector)

    [projector: projector]
  end

  defp build_projection_event(event, event_number, metadata) do
    Factory.build_recorded_event(
      data: event,
      event_number: event_number,
      stream_version: event_number,
      metadata: metadata
    )
  end
end
