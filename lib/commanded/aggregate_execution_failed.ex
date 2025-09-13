defmodule Commanded.AggregateExecutionFailed do
  @moduledoc """
  Exception raised when aggregate execution fails.
  """
  defexception [:aggregate_uuid, :command_type, :reason, :message]

  @type t :: %__MODULE__{
          aggregate_uuid: String.t() | nil,
          command_type: atom() | String.t() | nil,
          reason: term(),
          message: String.t()
        }

  def exception(opts) when is_list(opts) do
    aggregate_uuid = Keyword.get(opts, :aggregate_uuid)
    command_type = Keyword.get(opts, :command_type)
    reason = Keyword.get(opts, :reason)
    message = Keyword.get(opts, :message, build_message(aggregate_uuid, command_type, reason))

    %__MODULE__{
      aggregate_uuid: aggregate_uuid,
      command_type: command_type,
      reason: reason,
      message: message
    }
  end

  def exception(_) do
    %__MODULE__{
      aggregate_uuid: nil,
      command_type: nil,
      reason: nil,
      message: "Aggregate execution failed"
    }
  end

  defp build_message(uuid, command_type, reason) do
    base = "Aggregate execution failed"

    uuid_part = if uuid, do: " for aggregate '#{uuid}'", else: ""
    command_part = if command_type, do: " executing command '#{inspect(command_type)}'", else: ""
    reason_part = if reason, do: ", reason: #{inspect(reason)}", else: ""

    base <> uuid_part <> command_part <> reason_part
  end

  @doc """
  Factory function to create an AggregateExecutionFailed exception.
  """
  def new(opts \\ []) do
    exception(opts)
  end
end
