defmodule Commanded.MockProjectionCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  import Mox

  alias Commanded.EventStore.Adapters.Mock, as: MockEventStore
  alias Commanded.Projections.Repo
  alias Commanded.Projections.Setup
  alias Commanded.TestSupport.MockEventStoreHelpers
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Mox
      import Commanded.TestSupport.MockEventStoreHelpers

      alias Commanded.EventStore.Adapters.Mock, as: MockEventStore
    end
  end

  setup [:set_mox_global, :stub_event_store, :verify_on_exit!]

  setup_all do
    start_supervised!(Repo)
    :ok = Setup.ensure_projection_tables!()
    :ok = Sandbox.mode(Repo, :manual)

    :ok
  end

  setup do
    start_supervised!({TestApplication, event_store: [adapter: MockEventStore]})
    Sandbox.checkout(Repo)

    :ok
  end

  def stub_event_store(_context) do
    MockEventStoreHelpers.stub_common_event_store()
    MockEventStoreHelpers.stub_subscribe_to_for_projections()
    :ok
  end
end
