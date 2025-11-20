defmodule Commanded.Projections.EctoProjectionTest do
  use ExUnit.Case

  import Commanded.Projections.ProjectionAssertions

  alias Commanded.Projections.Events.{AnEvent, AnotherEvent, ErrorEvent, IgnoredEvent}
  alias Commanded.Projections.Projection
  alias Commanded.Projections.Repo
  alias Ecto.Adapters.SQL.Sandbox

  defmodule Projector do
    use Commanded.Projections.Ecto,
      application: TestApplication,
      name: "Projector",
      repo: Commanded.Projections.Repo

    project(%AnEvent{name: name}, _metadata, fn multi ->
      Ecto.Multi.insert(multi, :my_projection, %Projection{name: name})
    end)

    project(%AnotherEvent{name: name}, fn multi ->
      Ecto.Multi.insert(multi, :my_projection, %Projection{name: name})
    end)

    project(%ErrorEvent{}, fn multi ->
      Ecto.Multi.error(multi, :my_projection, :failure)
    end)
  end

  setup do
    start_supervised!(TestApplication)
    Sandbox.checkout(Repo)
  end

  test "should handle a projected event" do
    assert :ok == Projector.handle(%AnEvent{}, %{handler_name: "Projector", event_number: 1})

    assert_projections(Projection, ["AnEvent"])
    assert_seen_event("Projector", 1)
  end

  test "should handle two different types of projected events" do
    assert :ok == Projector.handle(%AnEvent{}, %{handler_name: "Projector", event_number: 1})
    assert :ok == Projector.handle(%AnotherEvent{}, %{handler_name: "Projector", event_number: 2})

    assert_projections(Projection, ["AnEvent", "AnotherEvent"])
    assert_seen_event("Projector", 2)
  end

  test "should ignore already projected event" do
    assert :ok == Projector.handle(%AnEvent{}, %{handler_name: "Projector", event_number: 1})
    assert :ok == Projector.handle(%AnEvent{}, %{handler_name: "Projector", event_number: 1})
    assert :ok == Projector.handle(%AnEvent{}, %{handler_name: "Projector", event_number: 1})

    assert_projections(Projection, ["AnEvent"])
    assert_seen_event("Projector", 1)
  end

  test "should ignore unprojected event" do
    assert :ok == Projector.handle(%IgnoredEvent{}, %{event_number: 1})

    assert_projections(Projection, [])
  end

  test "should ignore unprojected events amongst projections" do
    assert :ok == Projector.handle(%AnEvent{}, %{handler_name: "Projector", event_number: 1})
    assert :ok == Projector.handle(%IgnoredEvent{}, %{handler_name: "Projector", event_number: 2})
    assert :ok == Projector.handle(%AnotherEvent{}, %{handler_name: "Projector", event_number: 3})
    assert :ok == Projector.handle(%IgnoredEvent{}, %{handler_name: "Projector", event_number: 4})

    assert_projections(Projection, ["AnEvent", "AnotherEvent"])
    assert_seen_event("Projector", 3)
  end

  test "should prevent first event being projected more than once" do
    tasks =
      Enum.map(1..5, fn _index ->
        Task.async(Projector, :handle, [
          %AnEvent{name: "Event1"},
          %{handler_name: "Projector", event_number: 1}
        ])
      end)

    results = Task.await_many(tasks)

    assert Enum.uniq(results) == [:ok]

    assert_projections(Projection, ["Event1"])
    assert_seen_event("Projector", 1)
  end

  test "should prevent an event being projected more than once" do
    Projector.handle(%AnEvent{name: "Event1"}, %{handler_name: "Projector", event_number: 1})
    Projector.handle(%AnEvent{name: "Event2"}, %{handler_name: "Projector", event_number: 2})

    tasks =
      Enum.map(1..5, fn _index ->
        Task.async(Projector, :handle, [
          %AnEvent{name: "Event3"},
          %{handler_name: "Projector", event_number: 3}
        ])
      end)

    results = Task.await_many(tasks)

    assert Enum.uniq(results) == [:ok]

    assert_projections(Projection, ["Event1", "Event2", "Event3"])
    assert_seen_event("Projector", 3)
  end

  test "should prevent an event being projected more than once after an ignored event" do
    Projector.handle(%AnEvent{name: "Event1"}, %{handler_name: "Projector", event_number: 1})
    Projector.handle(%AnEvent{name: "Event2"}, %{handler_name: "Projector", event_number: 2})
    Projector.handle(%IgnoredEvent{name: "Event2"}, %{handler_name: "Projector", event_number: 3})

    tasks =
      Enum.map(1..5, fn _index ->
        Task.async(Projector, :handle, [
          %AnEvent{name: "Event4"},
          %{handler_name: "Projector", event_number: 4}
        ])
      end)

    results = Task.await_many(tasks)

    assert Enum.uniq(results) == [:ok]

    assert_projections(Projection, ["Event1", "Event2", "Event4"])
    assert_seen_event("Projector", 4)
  end

  test "should return an error on failure" do
    assert {:error, :failure} ==
             Projector.handle(%ErrorEvent{}, %{handler_name: "Projector", event_number: 1})

    assert_projections(Projection, [])
  end

  test "should ensure repo is configured" do
    repo = Application.get_env(:commanded, Commanded.Projections.Ecto)

    try do
      Application.delete_env(:commanded, Commanded.Projections.Ecto)

      assert_raise RuntimeError,
                   "Commanded Ecto projections expects :repo to be configured in environment",
                   fn ->
                     Code.eval_string("""
                     defmodule UnconfiguredProjector do
                       use Commanded.Projections.Ecto, application: TestApplication, name: "projector"
                     end
                     """)
                   end
    after
      if repo, do: Application.put_env(:commanded, Commanded.Projections.Ecto, repo)
    end
  end

  test "should allow to set `:repo` as an option" do
    repo = Application.get_env(:commanded, Commanded.Projections.Ecto)

    try do
      Application.delete_env(:commanded, Commanded.Projections.Ecto)

      assert Code.eval_string("""
             defmodule ProjectorConfiguredViaOpts do
               use Commanded.Projections.Ecto,
                 application: TestApplication,
                 name: "projector",
                 repo: Commanded.Projections.Repo
             end
             """)
    after
      if repo, do: Application.put_env(:commanded, Commanded.Projections.Ecto, repo)
    end
  end

  defmodule UnnamedProjector do
    use Commanded.Projections.Ecto,
      application: TestApplication,
      repo: Commanded.Projections.Repo
  end

  test "should ensure projection name is present on start" do
    expected_error =
      "Commanded.Projections.EctoProjectionTest.UnnamedProjector expects :name option"

    assert_raise ArgumentError, expected_error, fn ->
      UnnamedProjector.start_link()
    end
  end

  describe "concurrency validation" do
    test "should allow concurrency: 1" do
      defmodule TestConcurrency1Projector do
        use Commanded.Projections.Ecto,
          application: TestApplication,
          name: "TestConcurrency1Projector",
          repo: Commanded.Projections.Repo,
          concurrency: 1

        project(%AnEvent{name: name}, _metadata, fn multi ->
          Ecto.Multi.insert(multi, :projection, %Projection{name: name})
        end)
      end

      assert Code.ensure_loaded?(TestConcurrency1Projector)
    end

    test "should allow no concurrency option" do
      defmodule TestNoConcurrencyProjector do
        use Commanded.Projections.Ecto,
          application: TestApplication,
          name: "TestNoConcurrencyProjector",
          repo: Commanded.Projections.Repo

        project(%AnEvent{name: name}, _metadata, fn multi ->
          Ecto.Multi.insert(multi, :projection, %Projection{name: name})
        end)
      end

      assert Code.ensure_loaded?(TestNoConcurrencyProjector)
    end

    test "should reject concurrency > 1 in top-level options" do
      assert_raise CompileError, ~r/Ecto projections do not support :concurrency > 1/, fn ->
        defmodule TestConcurrencyRejectedProjector do
          use Commanded.Projections.Ecto,
            application: TestApplication,
            name: "TestConcurrencyRejectedProjector",
            repo: Commanded.Projections.Repo,
            concurrency: 4

          project(%AnEvent{name: name}, _metadata, fn multi ->
            Ecto.Multi.insert(multi, :projection, %Projection{name: name})
          end)
        end
      end
    end

    test "error message should explain the risk" do
      error =
        assert_raise CompileError, fn ->
          defmodule TestErrorMessageProjector do
            use Commanded.Projections.Ecto,
              application: TestApplication,
              name: "TestErrorMessageProjector",
              repo: Commanded.Projections.Repo,
              concurrency: 2

            project(%AnEvent{name: name}, _metadata, fn multi ->
              Ecto.Multi.insert(multi, :projection, %Projection{name: name})
            end)
          end
        end

      assert error.description =~ "out-of-order event processing"
      assert error.description =~ "silent data loss"
      assert error.description =~ ":batch_size"
    end

    test "should explain batch_size as alternative" do
      error =
        assert_raise CompileError, fn ->
          defmodule TestBatchSizeAlternativeProjector do
            use Commanded.Projections.Ecto,
              application: TestApplication,
              name: "TestBatchSizeAlternativeProjector",
              repo: Commanded.Projections.Repo,
              concurrency: 5

            project(%AnEvent{name: name}, _metadata, fn multi ->
              Ecto.Multi.insert(multi, :projection, %Projection{name: name})
            end)
          end
        end

      assert error.description =~ "Use :batch_size instead"
    end
  end

  describe "batch_size and concurrency mutual exclusivity" do
    test "should allow batch_size with concurrency: 1" do
      defmodule TestBatchAndConcurrency1Projector do
        use Commanded.Projections.Ecto,
          application: TestApplication,
          name: "TestBatchAndConcurrency1Projector",
          repo: Commanded.Projections.Repo,
          batch_size: 10,
          concurrency: 1

        project_batch(fn events, multi ->
          Enum.reduce(events, multi, fn {%AnEvent{name: name}, _metadata}, multi ->
            Ecto.Multi.insert(multi, {:projection, name}, %Projection{name: name})
          end)
        end)
      end

      assert Code.ensure_loaded?(TestBatchAndConcurrency1Projector)
    end

    test "should reject batch_size with concurrency > 1" do
      assert_raise CompileError, ~r/Ecto projections do not support :concurrency > 1/, fn ->
        defmodule TestBatchAndConcurrencyRejectedProjector do
          use Commanded.Projections.Ecto,
            application: TestApplication,
            name: "TestBatchAndConcurrencyRejectedProjector",
            repo: Commanded.Projections.Repo,
            batch_size: 10,
            concurrency: 4

          project_batch(fn events, multi ->
            Enum.reduce(events, multi, fn {%AnEvent{name: name}, _metadata}, multi ->
              Ecto.Multi.insert(multi, {:projection, name}, %Projection{name: name})
            end)
          end)
        end
      end
    end
  end

  describe "invalid concurrency values" do
    test "should reject atom concurrency value" do
      assert_raise CompileError, ~r/Invalid :concurrency value :foo/, fn ->
        defmodule TestAtomConcurrencyProjector do
          use Commanded.Projections.Ecto,
            application: TestApplication,
            name: "TestAtomConcurrencyProjector",
            repo: Commanded.Projections.Repo,
            concurrency: :foo

          project(%AnEvent{name: name}, _metadata, fn multi ->
            Ecto.Multi.insert(multi, :projection, %Projection{name: name})
          end)
        end
      end
    end

    test "should reject string concurrency value" do
      assert_raise CompileError, ~r/Invalid :concurrency value "2"/, fn ->
        defmodule TestStringConcurrencyProjector do
          use Commanded.Projections.Ecto,
            application: TestApplication,
            name: "TestStringConcurrencyProjector",
            repo: Commanded.Projections.Repo,
            concurrency: "2"

          project(%AnEvent{name: name}, _metadata, fn multi ->
            Ecto.Multi.insert(multi, :projection, %Projection{name: name})
          end)
        end
      end
    end

    test "should reject list concurrency value" do
      assert_raise CompileError, ~r/Invalid :concurrency value \[1, 2\]/, fn ->
        defmodule TestListConcurrencyProjector do
          use Commanded.Projections.Ecto,
            application: TestApplication,
            name: "TestListConcurrencyProjector",
            repo: Commanded.Projections.Repo,
            concurrency: [1, 2]

          project(%AnEvent{name: name}, _metadata, fn multi ->
            Ecto.Multi.insert(multi, :projection, %Projection{name: name})
          end)
        end
      end
    end

    test "should reject zero concurrency value" do
      assert_raise CompileError, ~r/Invalid :concurrency value 0/, fn ->
        defmodule TestZeroConcurrencyProjector do
          use Commanded.Projections.Ecto,
            application: TestApplication,
            name: "TestZeroConcurrencyProjector",
            repo: Commanded.Projections.Repo,
            concurrency: 0

          project(%AnEvent{name: name}, _metadata, fn multi ->
            Ecto.Multi.insert(multi, :projection, %Projection{name: name})
          end)
        end
      end
    end

    test "should reject negative concurrency value" do
      assert_raise CompileError,
                   ~r/Invalid :concurrency value.*Expected a positive integer/,
                   fn ->
                     defmodule TestNegativeConcurrencyProjector do
                       use Commanded.Projections.Ecto,
                         application: TestApplication,
                         name: "TestNegativeConcurrencyProjector",
                         repo: Commanded.Projections.Repo,
                         concurrency: -1

                       project(%AnEvent{name: name}, _metadata, fn multi ->
                         Ecto.Multi.insert(multi, :projection, %Projection{name: name})
                       end)
                     end
                   end
    end

    test "error message should specify expected type" do
      error =
        assert_raise CompileError, fn ->
          defmodule TestErrorMessageTypeProjector do
            use Commanded.Projections.Ecto,
              application: TestApplication,
              name: "TestErrorMessageTypeProjector",
              repo: Commanded.Projections.Repo,
              concurrency: :bad_value

            project(%AnEvent{name: name}, _metadata, fn multi ->
              Ecto.Multi.insert(multi, :projection, %Projection{name: name})
            end)
          end
        end

      assert error.description =~ "Expected a positive integer"
    end
  end
end
