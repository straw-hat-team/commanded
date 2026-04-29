defmodule Commanded.TestSupport.RetryStopOnceAggregate do
  alias Commanded.Aggregates.ExecutionContext

  @derive Jason.Encoder
  defstruct []

  defmodule Command do
    @derive Jason.Encoder
    defstruct [:uuid]
  end

  defmodule Tracker do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)
    end

    def stop_once(uuid) do
      Agent.get_and_update(__MODULE__, fn seen ->
        if MapSet.member?(seen, uuid) do
          {:ok, seen}
        else
          {:stop, MapSet.put(seen, uuid)}
        end
      end)
    end
  end

  def before_execute(_aggregate_state, %ExecutionContext{command: %Command{uuid: uuid}}) do
    case Tracker.stop_once(uuid) do
      :stop ->
        Process.exit(self(), :normal)

      :ok ->
        :ok
    end
  end

  def execute(%__MODULE__{}, %Command{}), do: []
end
