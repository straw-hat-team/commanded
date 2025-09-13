defmodule Commanded.WrongExpectedVersion do
  @moduledoc """
  Exception raised when the expected version doesn't match the actual stream version.
  """
  defexception [:expected_version, :actual_version, :stream_name, :message]

  @type t :: %__MODULE__{
          expected_version: integer() | :any_version | :no_stream | :stream_exists | nil,
          actual_version: integer() | nil,
          stream_name: String.t() | nil,
          message: String.t()
        }

  def exception(opts) when is_list(opts) do
    expected_version = Keyword.get(opts, :expected_version)
    actual_version = Keyword.get(opts, :actual_version)
    stream_name = Keyword.get(opts, :stream_name)
    message = Keyword.get(opts, :message, build_message(expected_version, actual_version, stream_name))

    %__MODULE__{
      expected_version: expected_version,
      actual_version: actual_version,
      stream_name: stream_name,
      message: message
    }
  end

  def exception(_) do
    %__MODULE__{
      expected_version: nil,
      actual_version: nil,
      stream_name: nil,
      message: "Wrong expected version"
    }
  end

  defp build_message(expected, actual, stream_name) do
    base_message = "Wrong expected version"

    stream_part = if stream_name, do: " for stream '#{stream_name}'", else: ""

    version_part =
      case {expected, actual} do
        {nil, nil} -> ""
        {expected, nil} -> ", expected: #{inspect(expected)}"
        {nil, actual} -> ", actual: #{actual}"
        {expected, actual} -> ", expected: #{inspect(expected)}, actual: #{actual}"
      end

    base_message <> stream_part <> version_part
  end

  @doc """
  Factory function to create a WrongExpectedVersion exception.
  """
  def new(opts \\ []) do
    exception(opts)
  end
end
