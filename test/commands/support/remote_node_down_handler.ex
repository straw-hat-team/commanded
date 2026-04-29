defmodule Commanded.Commands.RemoteNodeDownHandler do
  @moduledoc false
  @behaviour Commanded.Commands.Handler

  alias Commanded.Commands.{RemoteNodeDownAggregate, RemoteNodeDownCommand}

  def handle(%RemoteNodeDownAggregate{}, %RemoteNodeDownCommand{} = command) do
    %RemoteNodeDownCommand{
      aggregate_uuid: aggregate_uuid,
      notify: notify,
      sleep_in_ms: sleep_in_ms
    } = command

    send(notify, {:remote_command_started, aggregate_uuid, node()})
    :timer.sleep(sleep_in_ms)

    []
  end
end
