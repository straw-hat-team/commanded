defmodule Commanded.Projections.Repo.Migrations.CreateProjectionVersions do
  alias Commanded.Projections.Ecto.Migrations.V01CreateProjectionVersionsTable

  use Ecto.Migration

  def up do
    V01CreateProjectionVersionsTable.up()
  end

  def down do
    V01CreateProjectionVersionsTable.down()
  end
end
