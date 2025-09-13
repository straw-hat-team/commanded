defmodule Commanded.AlreadySeenEvent do
  @moduledoc """
  Exception raised when an event handler encounters an event it has already processed.
  """
  defexception [:event_id, :handler_name, :message]

  @type t :: %__MODULE__{
          event_id: String.t() | nil,
          handler_name: atom() | String.t() | nil,
          message: String.t()
        }

  def exception(opts) when is_list(opts) do
    event_id = Keyword.get(opts, :event_id)
    handler_name = Keyword.get(opts, :handler_name)
    message = Keyword.get(opts, :message, build_message(event_id, handler_name))

    %__MODULE__{
      event_id: event_id,
      handler_name: handler_name,
      message: message
    }
  end

  def exception(_) do
    %__MODULE__{
      event_id: nil,
      handler_name: nil,
      message: "Already seen event"
    }
  end

  defp build_message(event_id, handler_name) do
    base = "Already seen event"

    id_part = if event_id, do: " '#{event_id}'", else: ""
    handler_part = if handler_name, do: " in handler '#{handler_name}'", else: ""

    base <> id_part <> handler_part
  end

  @doc """
  Factory function to create an AlreadySeenEvent exception.
  """
  def new(opts \\ []) do
    exception(opts)
  end
end
