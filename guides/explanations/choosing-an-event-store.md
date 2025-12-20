# Choosing an event store

You must decide which event store to use with Commanded. You have a choice between the following event stores:

- PostgreSQL-based Elixir [EventStore](https://github.com/commanded/eventstore) with `Commanded.EventStore.Adapters.EventStore` Adapter.
- [KurrentDB/EventStoreDB](https://www.kurrent.io/) with `Commanded.EventStore.Adapters.KurrentDB` Adapter (requires `:spear` dependency).

There is also an [in-memory event store adapter](./in-memory-event-store.md) for **test use only**.

Want to use a different event store? Then you will need to write your own event store provider as described below.

---

## PostgreSQL-based Elixir EventStore

Use `Commanded.EventStore.Adapters.EventStore` to persist events to a PostgreSQL database. As the name implies, this is the adapter for [EventStore](https://github.com/commanded/eventstore), which is open-source event store using PostgreSQL for persistence and implemented in Elixir.

---

## KurrentDB / EventStoreDB

Use `Commanded.EventStore.Adapters.KurrentDB` to persist events to [KurrentDB](https://www.kurrent.io/) (formerly EventStoreDB). This adapter uses the [Spear](https://github.com/NFIBrokerage/spear) gRPC client library.

### Requirements

- EventStoreDB v23.x or later
- Add the `:spear` dependency to your project

### Installation

Add `:spear` to your dependencies in `mix.exs`:

```elixir
defp deps do
  [
    {:commanded, "~> 3.0"},
    {:spear, "~> 1.4"}
  ]
end
```

### Configuration

Configure your Commanded application to use the KurrentDB adapter:

```elixir
defmodule MyApp.Application do
  use Commanded.Application, otp_app: :my_app
end
```

In your config:

```elixir
config :my_app, MyApp.Application,
  event_store: [
    adapter: Commanded.EventStore.Adapters.KurrentDB,
    connection_string: "esdb://localhost:2113",
    serializer: Commanded.Serialization.JsonSerializer
  ]
```

### Connection String

The connection string follows the EventStoreDB format:

```
esdb://localhost:2113
esdb://user:password@localhost:2113?tls=true
```

### TLS Configuration

For secure connections, configure TLS options:

```elixir
config :my_app, MyApp.Application,
  event_store: [
    adapter: Commanded.EventStore.Adapters.KurrentDB,
    connection_string: "esdb://localhost:2113?tls=true",
    mint_opts: [
      transport_opts: [
        cacertfile: "/path/to/ca.crt"
      ]
    ],
    serializer: Commanded.Serialization.JsonSerializer
  ]
```

### Running EventStoreDB

You can run EventStoreDB locally using Docker:

```bash
docker run -d --name eventstoredb -p 2113:2113 \
  -e EVENTSTORE_INSECURE=true \
  -e EVENTSTORE_RUN_PROJECTIONS=All \
  -e EVENTSTORE_START_STANDARD_PROJECTIONS=true \
  eventstore/eventstore:23.10.0-bookworm-slim
```

### Snapshots

Since EventStoreDB doesn't have native snapshot support, the adapter stores snapshots as events in dedicated streams with the prefix `snapshot-`. For example, snapshots for aggregate `123` are stored in stream `snapshot-123`.

---

## Writing your own event store provider

To use an alternative event store with Commanded you will need to implement the `Commanded.EventStore.Adapter` behaviour. This defines the contract to be implemented by an adapter module to allow an event store to be used with Commanded. Tests to verify an adapter conforms to the behaviour are provided in `test/event_store_adapter`.
