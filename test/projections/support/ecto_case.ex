defmodule Commanded.Projections.EctoCase do
  use ExUnit.CaseTemplate

  alias Commanded.Projections.Repo
  alias Commanded.Projections.Setup
  alias Ecto.Adapters.SQL.Sandbox

  using options do
    quote do
      use ExUnit.Case, unquote(options)
    end
  end

  setup_all do
    start_supervised!(Repo)
    :ok = Setup.ensure_projection_tables!()
    :ok = Sandbox.mode(Repo, :manual)

    :ok
  end

  setup do
    start_supervised!(TestApplication)
    Sandbox.checkout(Repo)

    :ok
  end
end
