defmodule Commanded.StreamExists do
  @moduledoc """
  Exception raised when attempting to create a stream that already exists.
  """
  defexception [:stream_name, :message]

  @type t :: %__MODULE__{
          stream_name: String.t() | nil,
          message: String.t()
        }

  def exception(stream_name) when is_binary(stream_name) do
    %__MODULE__{
      stream_name: stream_name,
      message: "Stream '#{stream_name}' already exists"
    }
  end

  def exception(opts) when is_list(opts) do
    stream_name = Keyword.get(opts, :stream_name)
    message = Keyword.get(opts, :message, build_message(stream_name))

    %__MODULE__{
      stream_name: stream_name,
      message: message
    }
  end

  def exception(_) do
    %__MODULE__{
      stream_name: nil,
      message: "Stream already exists"
    }
  end

  @doc """
  Factory function to create a StreamExists exception.
  """
  def new(stream_name \\ nil) do
    exception(stream_name)
  end

  defp build_message(nil), do: "Stream already exists"
  defp build_message(stream_name), do: "Stream '#{stream_name}' already exists"
end
