defmodule Commanded.InvalidReturnValue do
  @moduledoc """
  Exception raised when a handler returns an invalid value.
  """
  defexception [:expected, :actual, :handler_name, :message]

  @type t :: %__MODULE__{
          expected: String.t() | nil,
          actual: term(),
          handler_name: atom() | String.t() | nil,
          message: String.t()
        }

  def exception(opts) when is_list(opts) do
    expected = Keyword.get(opts, :expected)
    actual = Keyword.get(opts, :actual)
    handler_name = Keyword.get(opts, :handler_name)
    message = Keyword.get(opts, :message, build_message(expected, actual, handler_name))

    %__MODULE__{
      expected: expected,
      actual: actual,
      handler_name: handler_name,
      message: message
    }
  end

  def exception(_) do
    %__MODULE__{
      expected: nil,
      actual: nil,
      handler_name: nil,
      message: "Invalid return value"
    }
  end

  defp build_message(expected, actual, handler_name) do
    base = "Invalid return value"

    handler_part = if handler_name, do: " from handler '#{handler_name}'", else: ""
    expected_part = if expected, do: ", expected: #{expected}", else: ""
    actual_part = ", actual: #{inspect(actual)}"

    base <> handler_part <> expected_part <> actual_part
  end

  @doc """
  Factory function to create an InvalidReturnValue exception.
  """
  def new(opts \\ []) do
    exception(opts)
  end
end
