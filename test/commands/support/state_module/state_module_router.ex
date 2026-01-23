defmodule Commanded.Commands.StateModuleRouter do
  @moduledoc false
  use Commanded.Commands.Router

  alias Commanded.Commands.StateModuleAggregate
  alias Commanded.Commands.StateModuleAggregate.State
  alias Commanded.Commands.StateModuleAggregate.{CreateCommand, UpdateCommand}

  dispatch [CreateCommand, UpdateCommand],
    to: StateModuleAggregate,
    initial_state: State,
    identity: :uuid
end
