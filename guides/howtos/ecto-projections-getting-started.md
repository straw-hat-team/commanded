# Ecto projections - Getting started

Commanded includes built-in support for read model projections using Ecto. You should already have [Ecto](https://github.com/elixir-ecto/ecto) installed and configured before proceeding. Please follow Ecto's [Getting Started](https://hexdocs.pm/ecto/getting-started.html) guide to get going first.

1. Add `:ecto` and `:ecto_sql` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [
        {:ecto, "~> 3.11"},
        {:ecto_sql, "~> 3.11"}
      ]
    end
    ```

2. Generate an Ecto migration in your app:

    ```console
    mix ecto.gen.migration create_projection_versions
    ```

3. Modify the generated migration, in `priv/repo/migrations`, to create the `projection_versions` table:

    ```elixir
    defmodule CreateProjectionVersions do
      use Ecto.Migration

      def change do
        create table(:projection_versions, primary_key: false) do
          add(:projection_name, :text, primary_key: true)
          add(:last_seen_event_number, :bigint)

          timestamps(type: :naive_datetime_usec)
        end
      end
    end
    ```

4. Run the Ecto migration:

    ```console
    mix ecto.migrate
    ```

5. Define your first read model projector:

    ```elixir
    defmodule MyApp.ExampleProjector do
      use Commanded.Projections.Ecto,
        application: MyApp.Application,
        repo: MyApp.Projections.Repo,
        name: "example_projection"
    end
    ```

    Alternatively, you can configure the repo globally in your config file:

    ```elixir
    # config/config.exs
    config :commanded, Commanded.Projections.Ecto,
      repo: MyApp.Projections.Repo
    ```

    And then omit the `:repo` option from your projectors:

    ```elixir
    defmodule MyApp.ExampleProjector do
      use Commanded.Projections.Ecto,
        application: MyApp.Application,
        name: "example_projection"
    end
    ```

Refer to the [Building Read Models with Ecto](building-read-models-with-ecto.html) guide for more detail on how to configure and use a read model projector.
