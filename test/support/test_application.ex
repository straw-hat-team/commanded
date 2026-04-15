defmodule TestApplication do
  alias Commanded.TestSupport.ProjectionsSetup

  use Commanded.Application,
    otp_app: :my_app,
    event_store: [
      adapter: Commanded.EventStore.Adapters.InMemory,
      serializer: Commanded.Serialization.JsonSerializer
    ]

  def init(config) do
    :ok = ProjectionsSetup.ensure_started!()

    {:ok, config}
  end
end
