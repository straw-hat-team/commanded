defmodule Commanded.Projections.Repo.Migrations.CreateProjectionVersionWithPrefix do
  alias Commanded.Projections.Ecto.Migrations.V01CreateProjectionVersionsTable

  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA test")
    V01CreateProjectionVersionsTable.up(prefix: "test")
  end

  def down do
    V01CreateProjectionVersionsTable.down(prefix: "test")
    execute("DROP SCHEMA test CASCADE")
  end
end
