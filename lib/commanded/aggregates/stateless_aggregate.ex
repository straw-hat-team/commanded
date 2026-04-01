defmodule Commanded.Aggregates.StatelessAggregate do
  @moduledoc false

  alias Commanded.Aggregates.ExecutionContext
  alias Commanded.Aggregate.Multi
  alias Commanded.Snapshotting
  alias Commanded.Aggregates.Aggregate
  alias Commanded.Aggregates.AggregateStateBuilder
  alias Commanded.Event.Mapper
  alias Commanded.EventStore
  alias Commanded.Application.Config

  require Logger

  def execute(application, aggregate_module, aggregate_uuid, context, _timeout) do
    aggregate = make_aggregate(application, aggregate_module, aggregate_uuid)
    aggregate = AggregateStateBuilder.populate(aggregate)

    {result, aggregate} = execute_command(context, aggregate)

    aggregate =
      if Snapshotting.snapshot_required?(aggregate.snapshotting, aggregate.aggregate_version) do
        do_take_snapshot(aggregate)
      else
        aggregate
      end

    ExecutionContext.format_reply(result, context, aggregate)
  end

  defp make_aggregate(application, aggregate_module, aggregate_uuid) do
    snapshot_options =
      application
      |> Config.get(:snapshotting)
      |> Kernel.||(%{})
      |> Map.get(aggregate_module, [])

    snapshotting = Snapshotting.new(application, aggregate_uuid, snapshot_options)

    %Aggregate{
      aggregate_module: aggregate_module,
      snapshotting: snapshotting,
      application: application,
      aggregate_uuid: aggregate_uuid
    }
  end

  defp before_execute_command(_aggregate_state, %ExecutionContext{before_execute: nil}), do: :ok

  defp before_execute_command(aggregate_state, %ExecutionContext{} = context) do
    %ExecutionContext{handler: handler, before_execute: before_execute} = context

    Kernel.apply(handler, before_execute, [aggregate_state, context])
  end

  defp execute_command(%ExecutionContext{} = context, %Aggregate{} = aggregate) do
    %ExecutionContext{command: command, handler: handler, function: function} = context
    %Aggregate{aggregate_state: aggregate_state} = aggregate

    Logger.debug(describe(aggregate) <> " executing command: " <> inspect(command))

    with :ok <- before_execute_command(aggregate_state, context) do
      case Kernel.apply(handler, function, [aggregate_state, command]) do
        {:error, _error} = reply ->
          {reply, aggregate}

        none when none in [:ok, nil, []] ->
          {{:ok, []}, aggregate}

        %Multi{} = multi ->
          case Multi.run(multi) do
            {:error, _error} = reply ->
              {reply, aggregate}

            {aggregate_state, pending_events} ->
              persist_events(pending_events, aggregate_state, context, aggregate)
          end

        {:ok, pending_events} ->
          apply_and_persist_events(pending_events, context, aggregate)

        pending_events ->
          apply_and_persist_events(pending_events, context, aggregate)
      end
    else
      {:error, _error} = reply ->
        {reply, aggregate}
    end
  rescue
    error ->
      stacktrace = __STACKTRACE__
      Logger.error(Exception.format(:error, error, stacktrace))

      {{:error, error, stacktrace}, aggregate}
  end

  defp persist_events(pending_events, aggregate_state, context, %Aggregate{} = aggregate) do
    %Aggregate{aggregate_version: expected_version} = aggregate

    with :ok <- append_to_stream(pending_events, context, aggregate) do
      aggregate_version = expected_version + length(pending_events)

      aggregate = %Aggregate{
        aggregate
        | aggregate_state: aggregate_state,
          aggregate_version: aggregate_version
      }

      {{:ok, pending_events}, aggregate}
    else
      {:error, :wrong_expected_version} ->
        # Fetch missing events from event store
        aggregate = AggregateStateBuilder.rebuild_from_events(aggregate)

        # Retry command if there are any attempts left
        case ExecutionContext.retry(context) do
          {:ok, context} ->
            Logger.debug(describe(aggregate) <> " wrong expected version, retrying command")

            execute_command(context, aggregate)

          reply ->
            Logger.debug(
              describe(aggregate) <> " wrong expected version, but not retrying command"
            )

            {reply, aggregate}
        end

      {:error, _error} = reply ->
        {reply, aggregate}
    end
  end

  defp apply_and_persist_events(pending_events, context, %Aggregate{} = aggregate) do
    %Aggregate{aggregate_module: aggregate_module, aggregate_state: aggregate_state} = aggregate

    pending_events = List.wrap(pending_events)
    aggregate_state = apply_events(aggregate_module, aggregate_state, pending_events)

    persist_events(pending_events, aggregate_state, context, aggregate)
  end

  defp apply_events(aggregate_module, aggregate_state, events) do
    Enum.reduce(events, aggregate_state, &aggregate_module.apply(&2, &1))
  end

  defp append_to_stream([], _context, _state), do: :ok

  defp append_to_stream(pending_events, %ExecutionContext{} = context, %Aggregate{} = state) do
    %Aggregate{
      application: application,
      aggregate_uuid: aggregate_uuid,
      aggregate_version: expected_version
    } = state

    %ExecutionContext{
      causation_id: causation_id,
      correlation_id: correlation_id,
      metadata: metadata
    } = context

    event_data =
      Mapper.map_to_event_data(pending_events,
        causation_id: causation_id,
        correlation_id: correlation_id,
        metadata: metadata
      )

    EventStore.append_to_stream(application, aggregate_uuid, expected_version, event_data)
  end

  defp do_take_snapshot(%Aggregate{} = state) do
    %Aggregate{
      aggregate_state: aggregate_state,
      aggregate_version: aggregate_version,
      snapshotting: snapshotting
    } = state

    Logger.debug(describe(state) <> " recording snapshot")

    case Snapshotting.take_snapshot(snapshotting, aggregate_version, aggregate_state) do
      {:ok, snapshotting} ->
        %Aggregate{state | snapshotting: snapshotting}

      {:error, error} ->
        Logger.warning(describe(state) <> " snapshot failed due to: " <> inspect(error))

        state
    end
  end

  defp describe(%Aggregate{} = aggregate) do
    %Aggregate{
      aggregate_module: aggregate_module,
      aggregate_uuid: aggregate_uuid,
      aggregate_version: aggregate_version
    } = aggregate

    "#{inspect(aggregate_module)}<#{aggregate_uuid}@#{aggregate_version}>"
  end
end
