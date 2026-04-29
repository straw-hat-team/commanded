defmodule Commanded.Middleware.MiddlewareTest do
  use ExUnit.Case

  import Commanded.Enumerable

  alias Commanded.Commands.ExecutionResult
  alias Commanded.Aggregates.{Lifespan, LifespanAggregate}
  alias Commanded.Aggregates.LifespanAggregate.Command, as: LifespanCommand
  alias Commanded.DefaultApp
  alias Commanded.Helpers.CommandAuditMiddleware

  alias Commanded.Middleware.Commands.{
    CommandHandler,
    CounterAggregateRoot,
    Fail,
    IncrementCount,
    RaiseError,
    Timeout
  }

  alias Commanded.Middleware.Pipeline
  alias Commanded.UUID

  defmodule FirstMiddleware do
    @behaviour Commanded.Middleware

    def before_dispatch(pipeline), do: pipeline
    def after_dispatch(pipeline), do: pipeline
    def after_failure(pipeline), do: pipeline
  end

  defmodule ModifyMetadataMiddleware do
    @behaviour Commanded.Middleware

    def before_dispatch(pipeline) do
      Pipeline.assign_metadata(pipeline, "updated_by", "ModifyMetadataMiddleware")
    end

    def after_dispatch(pipeline), do: pipeline
    def after_failure(pipeline), do: pipeline
  end

  defmodule LastMiddleware do
    @behaviour Commanded.Middleware

    def before_dispatch(pipeline), do: pipeline
    def after_dispatch(pipeline), do: pipeline
    def after_failure(pipeline), do: pipeline
  end

  defmodule Router do
    use Commanded.Commands.Router

    middleware FirstMiddleware
    middleware ModifyMetadataMiddleware
    middleware Commanded.Middleware.Logger
    middleware CommandAuditMiddleware
    middleware LastMiddleware

    dispatch [
               IncrementCount,
               Fail,
               RaiseError,
               Timeout
             ],
             to: CommandHandler,
             aggregate: CounterAggregateRoot,
             identity: :aggregate_uuid
  end

  defmodule RetryExhaustionRouter do
    use Commanded.Commands.Router

    alias Commanded.Aggregates.Lifespan
    alias Commanded.Aggregates.LifespanAggregate
    alias Commanded.Aggregates.LifespanAggregate.Command

    middleware CommandAuditMiddleware

    dispatch [Command],
      to: LifespanAggregate,
      identity: :uuid,
      lifespan: Lifespan
  end

  setup do
    start_supervised!(CommandAuditMiddleware)
    start_supervised!(DefaultApp)

    :ok
  end

  test "should call middleware for each command dispatch" do
    aggregate_uuid = UUID.uuid4()

    :ok =
      Router.dispatch(%IncrementCount{aggregate_uuid: aggregate_uuid, by: 1},
        application: DefaultApp
      )

    :ok =
      Router.dispatch(%IncrementCount{aggregate_uuid: aggregate_uuid, by: 2},
        application: DefaultApp
      )

    :ok =
      Router.dispatch(%IncrementCount{aggregate_uuid: aggregate_uuid, by: 3},
        application: DefaultApp
      )

    {dispatched, succeeded, failed} = CommandAuditMiddleware.count_commands()

    assert dispatched == 3
    assert succeeded == 3
    assert failed == 0

    dispatched_commands = CommandAuditMiddleware.dispatched_commands()
    succeeded_commands = CommandAuditMiddleware.succeeded_commands()

    assert pluck(dispatched_commands, :by) == [1, 2, 3]
    assert pluck(succeeded_commands, :by) == [1, 2, 3]
  end

  test "should execute middleware failure callback when aggregate process returns an error tagged tuple" do
    # force command handling to return an error
    {:error, :failed} =
      Router.dispatch(%Fail{aggregate_uuid: UUID.uuid4()}, application: DefaultApp)

    {dispatched, succeeded, failed} = CommandAuditMiddleware.count_commands()

    assert dispatched == 1
    assert succeeded == 0
    assert failed == 1
  end

  test "should execute middleware failure callback when aggregate process errors" do
    command = %RaiseError{aggregate_uuid: UUID.uuid4()}

    # Force command handling to error
    assert {:error, %RuntimeError{message: "failed"}} =
             Router.dispatch(command, application: DefaultApp)

    {dispatched, succeeded, failed} = CommandAuditMiddleware.count_commands()

    assert dispatched == 1
    assert succeeded == 0
    assert failed == 1
  end

  test "should execute middleware failure callback when aggregate process dies" do
    command = %Timeout{aggregate_uuid: UUID.uuid4()}

    # Force command handling to timeout so the aggregate process is terminated
    :ok =
      case Router.dispatch(command, application: DefaultApp, timeout: 50) do
        {:error, :aggregate_execution_timeout} -> :ok
        {:error, :aggregate_execution_failed} -> :ok
      end

    {dispatched, succeeded, failed} = CommandAuditMiddleware.count_commands()

    assert dispatched == 1
    assert succeeded == 0
    assert failed == 1
  end

  test "should let a middleware update the metadata" do
    command = %IncrementCount{aggregate_uuid: UUID.uuid4(), by: 1}

    assert {:ok, %ExecutionResult{metadata: metadata}} =
             Router.dispatch(
               command,
               application: DefaultApp,
               include_execution_result: true,
               metadata: %{"first_metadata" => "first_metadata"}
             )

    assert metadata == %{
             "first_metadata" => "first_metadata",
             "updated_by" => "ModifyMetadataMiddleware"
           }
  end

  test "should execute middleware failure callback when dispatcher retries are exhausted" do
    aggregate_uuid = UUID.uuid4()

    {:ok, ^aggregate_uuid} =
      Commanded.Aggregates.Supervisor.open_aggregate(
        DefaultApp,
        LifespanAggregate,
        aggregate_uuid
      )

    command = %LifespanCommand{uuid: aggregate_uuid, action: :noop, lifespan: :stop}

    results =
      dispatch_concurrently(fn ->
        RetryExhaustionRouter.dispatch(command, application: DefaultApp, retry_attempts: 0)
      end)

    assert Enum.any?(results, &match?({:ok, {:error, :too_many_attempts}}, &1))

    assert Enum.all?(results, fn
             {:ok, :ok} -> true
             {:ok, {:error, :too_many_attempts}} -> true
             _ -> false
           end)

    error_count = Enum.count(results, &match?({:ok, {:error, :too_many_attempts}}, &1))
    success_count = Enum.count(results, &match?({:ok, :ok}, &1))

    assert CommandAuditMiddleware.count_commands() ==
             {length(results), success_count, error_count}
  end

  defp dispatch_concurrently(fun, count \\ 10) do
    1..count
    |> Task.async_stream(fn _ -> fun.() end, ordered: false, timeout: 5_000)
    |> Enum.to_list()
  end
end
