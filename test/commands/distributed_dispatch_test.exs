defmodule Commanded.Commands.DistributedDispatchTest do
  use ExUnit.Case

  alias Commanded.Aggregates.Supervisor

  alias Commanded.Commands.{
    RemoteNodeDownAggregate,
    RemoteNodeDownCommand,
    RemoteNodeDownRouter
  }

  alias Commanded.{DistributedApp, Registration, UUID}

  @moduletag :distributed

  setup do
    {"", 0} = System.cmd("epmd", ["-daemon"])
    :ok = LocalCluster.start()

    {:ok, cluster} =
      LocalCluster.start_link(1,
        prefix: "commanded",
        applications: [:commanded]
      )

    {:ok, [remote_node]} = LocalCluster.nodes(cluster)

    start_supervised!(DistributedApp)
    start_distributed_app(remote_node)

    [current_node: node(), remote_node: remote_node]
  end

  test "should retry command execution when the aggregate node goes down", %{
    current_node: current_node,
    remote_node: remote_node
  } do
    aggregate_uuid = UUID.uuid4()
    aggregate_name = {DistributedApp, RemoteNodeDownAggregate, aggregate_uuid}

    command = %RemoteNodeDownCommand{
      aggregate_uuid: aggregate_uuid,
      notify: self(),
      sleep_in_ms: 500
    }

    assert {:ok, ^aggregate_uuid} =
             :rpc.call(remote_node, Supervisor, :open_aggregate, [
               DistributedApp,
               RemoteNodeDownAggregate,
               aggregate_uuid
             ])

    aggregate_pid = Registration.whereis_name(DistributedApp, aggregate_name)

    assert is_pid(aggregate_pid)
    assert node(aggregate_pid) == remote_node

    :erlang.monitor_node(remote_node, true)

    dispatch_task =
      Task.async(fn ->
        RemoteNodeDownRouter.dispatch(command,
          application: DistributedApp,
          retry_attempts: 1,
          timeout: 5_000
        )
      end)

    assert_receive {:remote_command_started, ^aggregate_uuid, ^remote_node}, 5_000

    :rpc.cast(remote_node, :erlang, :halt, [])

    assert_receive {:nodedown, ^remote_node}, 5_000
    assert_receive {:remote_command_started, ^aggregate_uuid, ^current_node}, 5_000
    assert :ok = Task.await(dispatch_task, 6_000)

    :erlang.monitor_node(remote_node, false)
  end

  defp start_distributed_app(remote_node) do
    reply_to = self()

    Node.spawn(remote_node, Commanded.DistributedTestHelper, :start_distributed_app, [reply_to])

    assert_receive {:distributed_app_started, ^remote_node}, 5_000
  end
end
