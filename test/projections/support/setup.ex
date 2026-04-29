defmodule Commanded.Projections.Setup do
  alias Commanded.Projections.Repo
  alias Ecto.Adapters.SQL

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

    :ok = ensure_projection_versions_table!()
    :ok = ensure_projection_versions_table!("test")
  end

  defp ensure_projection_versions_table!(prefix \\ nil) do
    if prefix do
      SQL.query!(Repo, ~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"), [])
    end

    projection_versions_table =
      case prefix do
        nil -> ~s("projection_versions")
        prefix -> ~s("#{prefix}"."projection_versions")
      end

    SQL.query!(
      Repo,
      """
      CREATE TABLE IF NOT EXISTS #{projection_versions_table} (
        projection_name text PRIMARY KEY,
        last_seen_event_number bigint,
        inserted_at timestamptz,
        updated_at timestamptz
      )
      """,
      []
    )

    :ok
  end
end
