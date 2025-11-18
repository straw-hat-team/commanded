defmodule Commanded.Projections.ProjectionVersionSchemaPrefixTest do
  use ExUnit.Case

  alias Commanded.Projections.Events.SchemaEvent
  alias Commanded.Projections.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    ecto_config = Application.get_env(:commanded, Commanded.Projections.Ecto)

    on_exit(fn ->
      if ecto_config do
        Application.put_env(:commanded, Commanded.Projections.Ecto, ecto_config)
      else
        Application.delete_env(:commanded, Commanded.Projections.Ecto)
      end
    end)

    start_supervised!(TestApplication)
    Sandbox.checkout(Repo)
  end

  describe "schema prefix" do
    test "should default to `nil` schema prefix when not specified" do
      defmodule DefaultSchemaPrefixProjector do
        use Commanded.Projections.Ecto,
          application: TestApplication,
          name: "default_schema_prefix_projector",
          repo: Commanded.Projections.Repo
      end

      assert_schema_prefix(DefaultSchemaPrefixProjector, nil)
    end

    test "should support static schema prefix" do
      defmodule StaticSchemaPrefixProjector do
        use Commanded.Projections.Ecto,
          application: TestApplication,
          name: "static_schema_prefix_projector",
          schema_prefix: "static_schema_prefix",
          repo: Commanded.Projections.Repo
      end

      assert_schema_prefix(StaticSchemaPrefixProjector, "static_schema_prefix")
    end

    test "should support static schema prefix in application config" do
      Application.put_env(:commanded, Commanded.Projections.Ecto,
        schema_prefix: "app_config_schema_prefix"
      )

      defmodule AppConfigSchemaPrefixProjector do
        use Commanded.Projections.Ecto,
          application: TestApplication,
          name: "app_config_schema_prefix_projector",
          repo: Commanded.Projections.Repo
      end

      assert_schema_prefix(AppConfigSchemaPrefixProjector, "app_config_schema_prefix")
    end

    test "should support dynamic schema prefix using one-arity anonymous function" do
      defmodule DynamicOneAritySchemaPrefixProjector do
        use Commanded.Projections.Ecto,
          application: TestApplication,
          name: "dynamic_schema_prefix_projector",
          schema_prefix: fn _event -> "dynamic_schema_prefix" end,
          repo: Commanded.Projections.Repo
      end

      assert_schema_prefix(DynamicOneAritySchemaPrefixProjector, "dynamic_schema_prefix")
    end

    test "should support dynamic schema prefix using two-arity anonymous function" do
      defmodule DynamicTwoAritySchemaPrefixProjector do
        use Commanded.Projections.Ecto,
          application: TestApplication,
          name: "dynamic_schema_prefix_projector",
          schema_prefix: fn _event, _metadata -> "dynamic_schema_prefix" end,
          repo: Commanded.Projections.Repo
      end

      assert_schema_prefix(DynamicTwoAritySchemaPrefixProjector, "dynamic_schema_prefix")
    end

    test "should support optional `schema_prefix/1` callback function" do
      defmodule SchemaPrefixCallbackProjector do
        use Commanded.Projections.Ecto,
          application: TestApplication,
          name: "schema_prefix_callback_projector",
          repo: Commanded.Projections.Repo

        @impl Commanded.Projections.Ecto
        def schema_prefix(_event), do: "callback_schema_prefix"
      end

      assert_schema_prefix(SchemaPrefixCallbackProjector, "callback_schema_prefix")
    end

    test "should support `schema_prefix/1` callback function with different schema per event" do
      defmodule SchemaPrefixPerEventCallbackProjector do
        use Commanded.Projections.Ecto,
          application: TestApplication,
          name: "schema_prefix_per_event_callback_projector",
          repo: Commanded.Projections.Repo

        @impl Commanded.Projections.Ecto
        def schema_prefix(%SchemaEvent{schema: schema}), do: schema
      end

      assert schema_prefix(
               SchemaPrefixPerEventCallbackProjector,
               %SchemaEvent{schema: "schema1"},
               %{}
             ) ==
               "schema1"

      assert schema_prefix(
               SchemaPrefixPerEventCallbackProjector,
               %SchemaEvent{schema: "schema2"},
               %{}
             ) ==
               "schema2"

      assert schema_prefix(
               SchemaPrefixPerEventCallbackProjector,
               %SchemaEvent{schema: "schema3"},
               %{}
             ) ==
               "schema3"
    end

    test "should support optional `schema_prefix/2` callback function" do
      defmodule SchemaPrefix2CallbackProjector do
        use Commanded.Projections.Ecto,
          application: TestApplication,
          name: "schema_prefix_callback_projector",
          repo: Commanded.Projections.Repo

        @impl Commanded.Projections.Ecto
        def schema_prefix(_event, _metadata), do: "callback_schema_prefix"
      end

      assert_schema_prefix(SchemaPrefix2CallbackProjector, "callback_schema_prefix")
    end

    test "should support `schema_prefix/2` callback function with different schema per event and metadata" do
      defmodule SchemaPrefixPerEventAndMetadataCallbackProjector do
        use Commanded.Projections.Ecto,
          application: TestApplication,
          name: "schema_prefix_per_event_callback_projector",
          repo: Commanded.Projections.Repo

        @impl Commanded.Projections.Ecto
        def schema_prefix(%SchemaEvent{schema: schema}, %{"key" => value}),
          do: schema <> "-" <> value
      end

      assert schema_prefix(
               SchemaPrefixPerEventAndMetadataCallbackProjector,
               %SchemaEvent{schema: "schema1"},
               %{"key" => "value1"}
             ) ==
               "schema1-value1"

      assert schema_prefix(
               SchemaPrefixPerEventAndMetadataCallbackProjector,
               %SchemaEvent{schema: "schema2"},
               %{"key" => "value2"}
             ) ==
               "schema2-value2"

      assert schema_prefix(
               SchemaPrefixPerEventAndMetadataCallbackProjector,
               %SchemaEvent{schema: "schema3"},
               %{"key" => "value3"}
             ) ==
               "schema3-value3"
    end

    test "should update the ProjectionVersion with a schema prefix" do
      defmodule TestPrefixProjector do
        use Commanded.Projections.Ecto,
          application: TestApplication,
          name: "TestPrefixProjector",
          schema_prefix: "test",
          repo: Commanded.Projections.Repo

        project(%SchemaEvent{}, & &1)
      end

      alias TestPrefixProjector.ProjectionVersion

      :ok =
        TestPrefixProjector.handle(%SchemaEvent{}, %{
          handler_name: "TestPrefixProjector",
          event_number: 1
        })

      projection_version = Repo.get(ProjectionVersion, "TestPrefixProjector", prefix: "test")

      assert projection_version.last_seen_event_number == 1
    end

    test "should error when configured with an invalid schema prefix" do
      assert_raise ArgumentError,
                   "expected :schema_prefix option to be a string or a one-arity or two-arity function, but got: :invalid",
                   fn ->
                     Code.eval_string("""
                     defmodule InvalidSchemaPrefixProjector do
                       use Commanded.Projections.Ecto,
                         application: TestApplication,
                         name: "invalid_schema_prefix_projector",
                         schema_prefix: :invalid,
                         repo: Commanded.Projections.Repo
                     end
                     """)
                   end
    end
  end

  defp assert_schema_prefix(projector, expected_prefix) do
    prefix = schema_prefix(projector, %SchemaEvent{}, %{})

    assert prefix == expected_prefix
  end

  defp schema_prefix(projector, event, metadata) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(projector, :schema_prefix, [event, metadata])
  end
end
