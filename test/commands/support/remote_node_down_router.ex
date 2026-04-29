defmodule Commanded.Commands.RemoteNodeDownRouter do
  @moduledoc false
  use Commanded.Commands.Router

  alias Commanded.Commands.{
    RemoteNodeDownAggregate,
    RemoteNodeDownCommand,
    RemoteNodeDownHandler
  }

  dispatch RemoteNodeDownCommand,
    to: RemoteNodeDownHandler,
    aggregate: RemoteNodeDownAggregate,
    identity: :aggregate_uuid
end
