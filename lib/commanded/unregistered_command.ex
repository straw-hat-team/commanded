defmodule Commanded.UnregisteredCommand do
  @moduledoc """
  Exception raised when attempting to dispatch a command that hasn't been registered.
  """
  defexception [:command_type, :message]

  @type t :: %__MODULE__{
          command_type: atom() | String.t() | nil,
          message: String.t()
        }

  def exception(nil) do
    %__MODULE__{
      command_type: nil,
      message: "Unregistered command"
    }
  end

  def exception(command_type) when is_atom(command_type) do
    %__MODULE__{
      command_type: command_type,
      message: "Unregistered command: #{inspect(command_type)}"
    }
  end

  def exception(opts) when is_list(opts) do
    command_type = Keyword.get(opts, :command_type)
    message = Keyword.get(opts, :message, build_message(command_type))

    %__MODULE__{
      command_type: command_type,
      message: message
    }
  end

  def exception(_) do
    %__MODULE__{
      command_type: nil,
      message: "Unregistered command"
    }
  end

  @doc """
  Factory function to create an UnregisteredCommand exception.
  """
  def new(command_type \\ nil) do
    exception(command_type)
  end

  defp build_message(nil), do: "Unregistered command"
  defp build_message(type), do: "Unregistered command: #{inspect(type)}"
end
