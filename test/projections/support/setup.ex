defmodule Commanded.Projections.Setup do
  alias Commanded.Projections.Repo

  defmodule CreateProjections do
    use Ecto.Migration

    def change do
      create table(:projections) do
        add(:name, :text)
      end
    end
  end

  def ensure_projection_tables! do
    case Ecto.Migrator.up(Repo, 20_171_001_000_000, CreateProjections) do
      :ok -> :ok
      :already_up -> :ok
    end
  end
end
