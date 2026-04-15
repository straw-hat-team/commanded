defmodule Commanded.TestSupport.ProjectionsSetup do
  use GenServer

  alias Commanded.Projections.Repo
  alias Ecto.Adapters.SQL.Sandbox

  defmodule CreateProjections do
    use Ecto.Migration

    def change do
      create table(:projections) do
        add(:name, :text)
      end
    end
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :pending, Keyword.put_new(opts, :name, __MODULE__))
  end

  def ensure_started! do
    GenServer.call(__MODULE__, :ensure_started, :infinity)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ensure_started, _from, :ready) do
    {:reply, :ok, :ready}
  end

  def handle_call(:ensure_started, _from, :pending) do
    :ok = ensure_repo_started()
    :ok = ensure_projection_tables()
    :ok = Sandbox.mode(Repo, :manual)

    {:reply, :ok, :ready}
  end

  defp ensure_repo_started do
    case Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp ensure_projection_tables do
    case Ecto.Migrator.up(Repo, 20_171_001_000_000, CreateProjections) do
      :ok -> :ok
      :already_up -> :ok
    end
  end
end
