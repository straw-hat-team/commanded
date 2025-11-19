if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Commanded.Projections.Ecto.Migrations.V01CreateProjectionVersionsTable do
    @moduledoc """
    Version 1: Creates the `projection_versions` table with timezone-aware timestamps.

    Use this migration for **new installations** (greenfield projects).

    ## Usage

        defmodule MyApp.Repo.Migrations.CreateProjectionVersionsTable do
          use Ecto.Migration

          def up do
            Commanded.Projections.Ecto.Migrations.V01CreateProjectionVersionsTable.up()
          end

          def down do
            Commanded.Projections.Ecto.Migrations.V01CreateProjectionVersionsTable.down()
          end
        end

    ## Options

      * `:prefix` - The database schema prefix. Defaults to `nil` (public schema).

    ## Examples

        # Default schema (public)
        Commanded.Projections.Ecto.Migrations.V01CreateProjectionVersionsTable.up()

        # Custom schema
        Commanded.Projections.Ecto.Migrations.V01CreateProjectionVersionsTable.up(prefix: "projections")

    """

    use Ecto.Migration

    def up(opts \\ []) do
      prefix = Keyword.get(opts, :prefix)

      create table(:projection_versions, primary_key: false, prefix: prefix) do
        add(:projection_name, :text, primary_key: true)
        add(:last_seen_event_number, :bigint)

        timestamps(type: :timestamptz)
      end
    end

    def down(opts \\ []) do
      prefix = Keyword.get(opts, :prefix)
      drop(table(:projection_versions, prefix: prefix))
    end
  end
end
