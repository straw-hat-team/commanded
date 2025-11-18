defmodule Commanded.Projections.EctoProjectionBatchTest do
  use ExUnit.Case

  import Commanded.Projections.ProjectionAssertions

  alias Commanded.Projections.Events.{AnEvent, AnotherEvent, ErrorEvent}
  alias Commanded.Projections.Projection
  alias Commanded.Projections.Repo
  alias Ecto.Adapters.SQL.Sandbox

  defmodule BatchProjector do
    use Commanded.Projections.Ecto,
      application: TestApplication,
      name: "BatchProjector",
      repo: Commanded.Projections.Repo,
      batch_size: 1

    project_batch fn events, multi ->
      projections =
        Enum.map(events, fn
          {%AnEvent{name: name}, _metadata} -> %{name: name}
          {%AnotherEvent{name: name}, _metadata} -> %{name: name}
          {%ErrorEvent{}, _metadata} -> :error
        end)

      if Enum.any?(projections, &(&1 == :error)) do
        Ecto.Multi.error(multi, :projection, :failure)
      else
        Ecto.Multi.insert_all(multi, :projection, Projection, projections)
      end
    end
  end

  setup do
    start_supervised!(TestApplication)
    Sandbox.checkout(Repo)
  end

  test "should handle multiple projected events" do
    assert :ok ==
             BatchProjector.handle_batch([
               {%AnEvent{}, %{handler_name: "BatchProjector", event_number: 1}},
               {%AnEvent{}, %{handler_name: "BatchProjector", event_number: 2}}
             ])

    assert_projections(Projection, ["AnEvent", "AnEvent"])
    assert_seen_event("BatchProjector", 2)
  end

  test "should handle two different types of projected events" do
    assert :ok ==
             BatchProjector.handle_batch([
               {%AnEvent{}, %{handler_name: "BatchProjector", event_number: 1}},
               {%AnotherEvent{}, %{handler_name: "BatchProjector", event_number: 2}}
             ])

    assert_projections(Projection, ["AnEvent", "AnotherEvent"])
    assert_seen_event("BatchProjector", 2)
  end

  test "should ignore already projected batch" do
    assert :ok ==
             BatchProjector.handle_batch([
               {%AnEvent{}, %{handler_name: "BatchProjector", event_number: 1}}
             ])

    assert :ok ==
             BatchProjector.handle_batch([
               {%AnEvent{}, %{handler_name: "BatchProjector", event_number: 1}}
             ])

    assert_projections(Projection, ["AnEvent"])
    assert_seen_event("BatchProjector", 1)
  end

  test "partial batch already seen should return an :ok" do
    assert :ok ==
             BatchProjector.handle_batch([
               {%AnEvent{name: "e1"}, %{handler_name: "BatchProjector", event_number: 1}},
               {%AnEvent{name: "e2"}, %{handler_name: "BatchProjector", event_number: 2}},
               {%AnEvent{name: "e3"}, %{handler_name: "BatchProjector", event_number: 3}}
             ])

    assert_projections(Projection, ["e1", "e2", "e3"])
    assert_seen_event("BatchProjector", 3)

    assert :ok ==
             BatchProjector.handle_batch([
               {%AnEvent{name: "e2"}, %{handler_name: "BatchProjector", event_number: 2}},
               {%AnEvent{name: "e3"}, %{handler_name: "BatchProjector", event_number: 3}},
               {%AnEvent{name: "e4"}, %{handler_name: "BatchProjector", event_number: 4}}
             ])

    assert_projections(Projection, ["e1", "e2", "e3", "e4"])
    assert_seen_event("BatchProjector", 4)
  end

  test "entire batches already seen should return an :ok" do
    assert :ok ==
             BatchProjector.handle_batch([
               {%AnEvent{name: "e1"}, %{handler_name: "BatchProjector", event_number: 1}},
               {%AnEvent{name: "e2"}, %{handler_name: "BatchProjector", event_number: 2}},
               {%AnEvent{name: "e3"}, %{handler_name: "BatchProjector", event_number: 3}}
             ])

    assert :ok ==
             BatchProjector.handle_batch([
               {%AnEvent{name: "e1"}, %{handler_name: "BatchProjector", event_number: 1}},
               {%AnEvent{name: "e2"}, %{handler_name: "BatchProjector", event_number: 2}},
               {%AnEvent{name: "e3"}, %{handler_name: "BatchProjector", event_number: 3}}
             ])
  end

  test "should return an error on failure" do
    assert {:error, :failure} ==
             BatchProjector.handle_batch([
               {%ErrorEvent{}, %{handler_name: "BatchProjector", event_number: 1}}
             ])

    assert_projections(Projection, [])
  end

  defmodule BatchProjectorAfterUpdateCallback do
    use Commanded.Projections.Ecto,
      application: TestApplication,
      name: "BatchProjectorAfterUpdateCallback",
      repo: Commanded.Projections.Repo,
      batch_size: 1

    project_batch fn events, multi ->
      projections =
        Enum.map(events, fn
          {%{name: name}, _metadata} -> %{name: name}
        end)

      Ecto.Multi.insert_all(multi, :projection, Projection, projections)
    end

    def after_update_batch(events, changes) do
      {%{pid: pid}, _metadata} = List.first(events)

      send(pid, {:after_update_batch, length(events), changes})

      :ok
    end
  end

  test "should call after_update_batch/2 callback" do
    assert :ok ==
             BatchProjectorAfterUpdateCallback.handle_batch([
               {%AnEvent{pid: self()},
                %{handler_name: "BatchProjectorAfterUpdateCallback", event_number: 1}},
               {%AnEvent{pid: self()},
                %{handler_name: "BatchProjectorAfterUpdateCallback", event_number: 2}},
               {%AnEvent{pid: self()},
                %{handler_name: "BatchProjectorAfterUpdateCallback", event_number: 3}}
             ])

    assert_receive {:after_update_batch, 3, _changes}
  end

  defmodule BatchProjectorCallbackWithChanges do
    use Commanded.Projections.Ecto,
      application: TestApplication,
      name: "BatchProjectorCallbackWithChanges",
      repo: Commanded.Projections.Repo,
      batch_size: 1

    project_batch fn events, multi ->
      projections =
        Enum.map(events, fn
          {%{name: name}, _metadata} -> %{name: name}
        end)

      Ecto.Multi.insert_all(multi, :projection, Projection, projections)
    end

    def after_update_batch(events, changes) do
      {%{pid: pid}, _metadata} = List.first(events)

      send(pid, {:after_update_batch_changes, changes})

      :ok
    end
  end

  test "after_update_batch/2 callback receives correct changes from Ecto.Multi" do
    assert :ok ==
             BatchProjectorCallbackWithChanges.handle_batch([
               {%AnEvent{pid: self()},
                %{handler_name: "BatchProjectorCallbackWithChanges", event_number: 1}},
               {%AnEvent{pid: self()},
                %{handler_name: "BatchProjectorCallbackWithChanges", event_number: 2}}
             ])

    assert_receive {:after_update_batch_changes, changes}
    assert Map.has_key?(changes, :lock_and_filter)
    assert Map.has_key?(changes, :track_projection_version)
    assert Map.has_key?(changes, :prepare_user_multi)
    assert Map.has_key?(changes, :projection)
  end

  defmodule BatchProjectorCallbackReturnsError do
    use Commanded.Projections.Ecto,
      application: TestApplication,
      name: "BatchProjectorCallbackReturnsError",
      repo: Commanded.Projections.Repo,
      batch_size: 1

    project_batch fn events, multi ->
      projections =
        Enum.map(events, fn
          {%{name: name}, _metadata} -> %{name: name}
        end)

      Ecto.Multi.insert_all(multi, :projection, Projection, projections)
    end

    def after_update_batch(_events, _changes) do
      {:error, :callback_failed}
    end
  end

  test "after_update_batch/2 callback error does not rollback transaction" do
    assert {:error, :callback_failed} ==
             BatchProjectorCallbackReturnsError.handle_batch([
               {%AnEvent{},
                %{handler_name: "BatchProjectorCallbackReturnsError", event_number: 1}}
             ])

    assert_projections(Projection, ["AnEvent"])
  end

  defmodule BatchProjectorCallbackRaises do
    use Commanded.Projections.Ecto,
      application: TestApplication,
      name: "BatchProjectorCallbackRaises",
      repo: Commanded.Projections.Repo,
      batch_size: 1

    project_batch fn events, multi ->
      projections =
        Enum.map(events, fn
          {%{name: name}, _metadata} -> %{name: name}
        end)

      Ecto.Multi.insert_all(multi, :projection, Projection, projections)
    end

    def after_update_batch(_events, _changes) do
      raise "Intentional callback exception"
    end
  end

  test "after_update_batch/2 callback exception does not rollback transaction" do
    assert_raise RuntimeError, "Intentional callback exception", fn ->
      BatchProjectorCallbackRaises.handle_batch([
        {%AnEvent{}, %{handler_name: "BatchProjectorCallbackRaises", event_number: 1}}
      ])
    end

    assert_projections(Projection, ["AnEvent"])
  end
end
