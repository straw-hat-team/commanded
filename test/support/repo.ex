defmodule Commanded.Projections.Repo do
  use Ecto.Repo,
    otp_app: :commanded,
    adapter: Ecto.Adapters.Postgres
end
