defmodule Commanded.RemoteNodeDown do
  @moduledoc """
  Exception raised when a remote node is down during command dispatch.
  """
  defexception [:node, :message]

  @type t :: %__MODULE__{
          node: atom() | nil,
          message: String.t()
        }

  def exception(node) when is_atom(node) do
    %__MODULE__{
      node: node,
      message: "Remote node '#{node}' is down"
    }
  end

  def exception(opts) when is_list(opts) do
    node = Keyword.get(opts, :node)
    message = Keyword.get(opts, :message, build_message(node))

    %__MODULE__{
      node: node,
      message: message
    }
  end

  def exception(_) do
    %__MODULE__{
      node: nil,
      message: "Remote node is down"
    }
  end

  @doc """
  Factory function to create a RemoteNodeDown exception.
  """
  def new(node \\ nil) do
    exception(node)
  end

  defp build_message(nil), do: "Remote node is down"
  defp build_message(node), do: "Remote node '#{node}' is down"
end
