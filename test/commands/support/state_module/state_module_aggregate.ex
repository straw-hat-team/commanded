defmodule Commanded.Commands.StateModuleAggregate do
  @moduledoc """
  An aggregate that uses a separate state module.
  This module defines only the behavior (execute/apply), not the state struct.
  The initial_state option in the router specifies which state module to use.
  """

  alias Commanded.Commands.StateModuleAggregate.State
  alias Commanded.Commands.StateModuleAggregate.{CreateCommand, UpdateCommand}
  alias Commanded.Commands.StateModuleAggregate.{CreatedEvent, UpdatedEvent}

  defmodule CreateCommand do
    @derive Jason.Encoder
    defstruct [:uuid, :name]
  end

  defmodule UpdateCommand do
    @derive Jason.Encoder
    defstruct [:uuid, :name]
  end

  defmodule CreatedEvent do
    @derive Jason.Encoder
    defstruct [:uuid, :name]
  end

  defmodule UpdatedEvent do
    @derive Jason.Encoder
    defstruct [:uuid, :name]
  end

  def execute(%State{uuid: nil}, %CreateCommand{uuid: uuid, name: name}) do
    %CreatedEvent{uuid: uuid, name: name}
  end

  def execute(%State{uuid: _uuid}, %UpdateCommand{uuid: uuid, name: name}) do
    %UpdatedEvent{uuid: uuid, name: name}
  end

  def apply(%State{} = state, %CreatedEvent{uuid: uuid, name: name}) do
    %State{state | uuid: uuid, name: name}
  end

  def apply(%State{} = state, %UpdatedEvent{name: name}) do
    %State{state | name: name}
  end
end
