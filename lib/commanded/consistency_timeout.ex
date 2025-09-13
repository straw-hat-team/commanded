defmodule Commanded.ConsistencyTimeout do
  @moduledoc """
  Exception raised when a consistency guarantee times out.
  """
  defexception [:timeout_ms, :consistency_level, :message]

  @type t :: %__MODULE__{
          timeout_ms: integer() | nil,
          consistency_level: atom() | list() | nil,
          message: String.t()
        }

  def exception(opts) when is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms)
    consistency_level = Keyword.get(opts, :consistency_level)
    message = Keyword.get(opts, :message, build_message(timeout_ms, consistency_level))

    %__MODULE__{
      timeout_ms: timeout_ms,
      consistency_level: consistency_level,
      message: message
    }
  end

  def exception(_) do
    %__MODULE__{
      timeout_ms: nil,
      consistency_level: nil,
      message: "Consistency timeout"
    }
  end

  defp build_message(timeout_ms, consistency_level) do
    base = "Consistency timeout"

    timeout_part = if timeout_ms, do: " after #{timeout_ms}ms", else: ""
    level_part = if consistency_level, do: " (#{inspect(consistency_level)})", else: ""

    base <> timeout_part <> level_part
  end

  @doc """
  Factory function to create a ConsistencyTimeout exception.
  """
  def new(opts \\ []) do
    exception(opts)
  end
end
