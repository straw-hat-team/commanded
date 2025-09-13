defmodule Commanded.SnapshotNotFound do
  @moduledoc """
  Exception raised when attempting to access a snapshot that doesn't exist.
  """
  defexception [:aggregate_uuid, :message]

  @type t :: %__MODULE__{
          aggregate_uuid: String.t() | nil,
          message: String.t()
        }

  def exception(aggregate_uuid) when is_binary(aggregate_uuid) do
    %__MODULE__{
      aggregate_uuid: aggregate_uuid,
      message: "Snapshot not found for aggregate '#{aggregate_uuid}'"
    }
  end

  def exception(opts) when is_list(opts) do
    aggregate_uuid = Keyword.get(opts, :aggregate_uuid)
    message = Keyword.get(opts, :message, build_message(aggregate_uuid))

    %__MODULE__{
      aggregate_uuid: aggregate_uuid,
      message: message
    }
  end

  def exception(_) do
    %__MODULE__{
      aggregate_uuid: nil,
      message: "Snapshot not found"
    }
  end

  @doc """
  Factory function to create a SnapshotNotFound exception.
  """
  def new(aggregate_uuid \\ nil) do
    exception(aggregate_uuid)
  end

  defp build_message(nil), do: "Snapshot not found"
  defp build_message(uuid), do: "Snapshot not found for aggregate '#{uuid}'"
end
