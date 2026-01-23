defmodule Commanded.Aggregates.Supervisor do
  @moduledoc """
  Supervises `Commanded.Aggregates.Aggregate` instance processes.
  """

  use DynamicSupervisor

  require Logger

  alias Commanded.Aggregates.Aggregate
  alias Commanded.Registration

  def start_link(opts) do
    {start_opts, supervisor_opts} =
      Keyword.split(opts, [:debug, :name, :timeout, :spawn_opt, :hibernate_after])

    DynamicSupervisor.start_link(__MODULE__, supervisor_opts, start_opts)
  end

  @doc """
  Open an aggregate instance process for the given aggregate module and unique
  identity.

  Returns `{:ok, aggregate_uuid}` when a process is successfully started, or is
  already running.

  ## Options

    - `:initial_state` - optional module that implements `initial_state/0` callback.
      If not provided, defaults to `aggregate_module`.

  """
  @type open_aggregate_opt :: {:initial_state, module()} | {:timeout, timeout()}

  @spec open_aggregate(
          application :: module(),
          aggregate_module :: module(),
          aggregate_uuid :: String.t(),
          opts :: [open_aggregate_opt()]
        ) :: {:ok, String.t()} | {:error, term()}
  def open_aggregate(application, aggregate_module, aggregate_uuid, opts \\ [])

  def open_aggregate(application, aggregate_module, aggregate_uuid, opts)
      when is_atom(application) and is_atom(aggregate_module) and is_binary(aggregate_uuid) do
    Logger.debug(fn ->
      "Locating aggregate process for `#{inspect(aggregate_module)}` with UUID " <>
        inspect(aggregate_uuid)
    end)

    supervisor_name = Module.concat([application, __MODULE__])
    aggregate_name = Aggregate.name(application, aggregate_module, aggregate_uuid)

    initial_state = Keyword.get(opts, :initial_state)
    timeout = Keyword.get(opts, :timeout, 5_000)

    args = [
      application: application,
      aggregate_module: aggregate_module,
      aggregate_uuid: aggregate_uuid,
      initial_state: initial_state
    ]

    case Registration.start_child(application, aggregate_name, supervisor_name, {Aggregate, args}) do
      {:ok, _pid} ->
        ensure_initial_state_or_return(
          application,
          aggregate_module,
          aggregate_uuid,
          initial_state,
          timeout
        )

      {:ok, _pid, _info} ->
        ensure_initial_state_or_return(
          application,
          aggregate_module,
          aggregate_uuid,
          initial_state,
          timeout
        )

      {:error, {:already_started, _pid}} ->
        ensure_initial_state_or_return(
          application,
          aggregate_module,
          aggregate_uuid,
          initial_state,
          timeout
        )

      reply ->
        reply
    end
  end

  def open_aggregate(_application, _aggregate_module, aggregate_uuid, _opts),
    do: {:error, {:unsupported_aggregate_identity_type, aggregate_uuid}}

  defp ensure_initial_state_or_return(
         application,
         aggregate_module,
         aggregate_uuid,
         initial_state,
         timeout
       ) do
    case ensure_initial_state_consistency(
           application,
           aggregate_module,
           aggregate_uuid,
           initial_state,
           timeout
         ) do
      :ok -> {:ok, aggregate_uuid}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_initial_state_consistency(
         application,
         aggregate_module,
         aggregate_uuid,
         initial_state,
         timeout
       ) do
    running_initial_state =
      Aggregate.initial_state_module(application, aggregate_module, aggregate_uuid, timeout)

    if running_initial_state == initial_state do
      :ok
    else
      {:error,
       {:conflicting_initial_state,
        %{
          aggregate_module: aggregate_module,
          aggregate_uuid: aggregate_uuid,
          requested_initial_state: initial_state,
          running_initial_state: running_initial_state
        }}}
    end
  catch
    :exit, {reason, _context} when reason in [:normal, :noproc] ->
      # If aggregate exited between registration and validation, let caller retry.
      :ok

    :exit, reason ->
      {:error, {:cannot_validate_initial_state, reason}}
  end

  def init(args) do
    DynamicSupervisor.init(strategy: :one_for_one, extra_arguments: [args])
  end
end
