import Config

alias Commanded.EventStore.Adapters.InMemory
alias Commanded.Serialization.JsonSerializer

config :logger, level: :info
config :logger, :console, level: :info, format: "[$level] $message\n"

# Suppress GenServer "terminating" / "killed" logs from expected process teardown during tests
config :logger, handle_otp_reports: false

config :ex_unit,
  assert_receive_timeout: 1_000,
  capture_log: [level: :debug],
  exclude: [:distributed, :eventstore_adapter]

config :opentelemetry,
  processors: [],
  traces_exporter: :none

config :commanded,
  assert_receive_event_timeout: 100,
  refute_receive_event_timeout: 100,
  dispatch_consistency_timeout: 100

default_app_config = [
  event_store: [adapter: InMemory, serializer: JsonSerializer],
  pubsub: :local,
  registry: :local
]

config :commanded, Commanded.Commands.ConsistencyApp, default_app_config
config :commanded, Commanded.DefaultApp, []
config :commanded, Commanded.DistributedApp, []
config :commanded, Commanded.Middleware.TenantApp, default_app_config
config :commanded, Commanded.TestApplication, default_app_config

config :commanded, event_stores: [TestEventStore]

config :commanded, TestEventStore,
  serializer: Commanded.Serialization.JsonSerializer,
  username: "postgres",
  password: "postgres",
  database: "eventstore_test",
  hostname: "localhost",
  pool_size: 5,
  pool_overflow: 0

config :commanded,
  ecto_repos: [Commanded.Projections.Repo]

config :commanded, Commanded.Projections.Repo,
  database: "commanded_projections_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox
