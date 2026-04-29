defmodule Commanded.DistributedTestHelper do
  alias Commanded.DistributedApp

  def start_distributed_app(reply_to) do
    {:ok, _pid} = DistributedApp.start_link()
    send(reply_to, {:distributed_app_started, node()})
    :timer.sleep(:infinity)
  end
end
