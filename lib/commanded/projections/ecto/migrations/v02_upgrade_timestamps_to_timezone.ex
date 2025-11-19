if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Commanded.Projections.Ecto.Migrations.V02UpgradeTimestampsToTimezone do
    @moduledoc """
    Version 2: Upgrades timestamps to timezone-aware types.

    Use this migration for **existing installations** that have the old schema without timezone-aware timestamps.

    ## Usage

        defmodule MyApp.Repo.Migrations.UpgradeProjectionVersionsTimestamps do
          use Ecto.Migration

          def up do
            Commanded.Projections.Ecto.Migrations.V02UpgradeTimestampsToTimezone.up()
          end

          def down do
            Commanded.Projections.Ecto.Migrations.V02UpgradeTimestampsToTimezone.down()
          end
        end

    ## Options

      * `:prefix` - The database schema prefix. Defaults to `nil` (public schema).

    ## Examples

        # Default schema (public)
        Commanded.Projections.Ecto.Migrations.V02UpgradeTimestampsToTimezone.up()

        # Custom schema
        Commanded.Projections.Ecto.Migrations.V02UpgradeTimestampsToTimezone.up(prefix: "projections")

    """

    use Ecto.Migration

    def up(opts \\ []) do
      prefix = Keyword.get(opts, :prefix)

      alter table(:projection_versions, prefix: prefix) do
        modify(:inserted_at, :timestamptz, from: :naive_datetime_usec)
        modify(:updated_at, :timestamptz, from: :naive_datetime_usec)
      end
    end

    def down(opts \\ []) do
      prefix = Keyword.get(opts, :prefix)

      alter table(:projection_versions, prefix: prefix) do
        modify(:inserted_at, :naive_datetime_usec, from: :timestamptz)
        modify(:updated_at, :naive_datetime_usec, from: :timestamptz)
      end
    end
  end
end
