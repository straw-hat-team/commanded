defmodule Commanded.OpenTelemetry.TestRouter do
  use Commanded.Commands.Router

  alias Commanded.Middleware.Commands.CommandHandler
  alias Commanded.Middleware.Commands.CounterAggregateRoot
  alias Commanded.Middleware.Commands.IncrementCount
  alias Commanded.Middleware.Commands.RaiseError

  dispatch IncrementCount,
    to: CommandHandler,
    aggregate: CounterAggregateRoot,
    identity: :aggregate_uuid

  dispatch RaiseError,
    to: CommandHandler,
    aggregate: CounterAggregateRoot,
    identity: :aggregate_uuid
end
