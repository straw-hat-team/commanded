defmodule Commanded.DuplicateEvent do
  @moduledoc """
  Exception raised when attempting to append an event that already exists.
  """
  defexception [:event_id, :stream_name, :message]

  @type t :: %__MODULE__{
          event_id: String.t() | nil,
          stream_name: String.t() | nil,
          message: String.t()
        }

  def exception(opts) when is_list(opts) do
    event_id = Keyword.get(opts, :event_id)
    stream_name = Keyword.get(opts, :stream_name)
    message = Keyword.get(opts, :message, build_message(event_id, stream_name))

    %__MODULE__{
      event_id: event_id,
      stream_name: stream_name,
      message: message
    }
  end

  def exception(_) do
    %__MODULE__{
      event_id: nil,
      stream_name: nil,
      message: "Duplicate event"
    }
  end

  defp build_message(event_id, stream_name) do
    base = "Duplicate event"
    id_part = if event_id, do: " with ID '#{event_id}'", else: ""
    stream_part = if stream_name, do: " in stream '#{stream_name}'", else: ""
    base <> id_part <> stream_part
  end

  @doc """
  Factory function to create a DuplicateEvent exception.
  """
  def new(opts \\ []) do
    exception(opts)
  end
end
