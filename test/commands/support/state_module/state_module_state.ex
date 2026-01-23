defmodule Commanded.Commands.StateModuleAggregate.State do
  @moduledoc """
  A separate state module that defines the aggregate's state struct
  and the initial_state/0 callback.
  This could be a protobuf-generated module or any other struct module.
  """
  @derive Jason.Encoder
  defstruct [:uuid, :name]

  def initial_state, do: %__MODULE__{}
end
