defmodule Commanded.Projections.AfterUpdateCallbackTest do
  use ExUnit.Case

  alias Commanded.Projections.Events.AnEvent
  alias Commanded.Projections.Projection
  alias Commanded.Projections.Repo
  alias Ecto.Adapters.SQL.Sandbox

  defmodule Projector do
    use Commanded.Projections.Ecto,
      application: TestApplication,
      name: "Projector",
      repo: Commanded.Projections.Repo

    project(%AnEvent{name: name}, fn multi ->
      Ecto.Multi.insert(multi, :my_projection, %Projection{name: name})
    end)

    def after_update(event, metadata, changes) do
      %{pid: pid} = event

      send(pid, {:after_update, event, metadata, changes})

      :ok
    end
  end

  setup do
    start_supervised!(TestApplication)
    Sandbox.checkout(Repo)
  end

  test "should call `after_update/3` function with event, metadata, and changes" do
    event = %AnEvent{pid: self()}
    metadata = %{handler_name: "Projector", event_number: 1}

    assert :ok == Projector.handle(event, metadata)

    assert_receive {:after_update, ^event, ^metadata, changes}

    case Map.get(changes, :my_projection) do
      %Projection{name: "AnEvent"} -> :ok
      _ -> flunk("invalid changes")
    end
  end
end
