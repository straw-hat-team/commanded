# Choosing an event store

You must decide which event store to use with Commanded. You have a choice between two existing event stores:

- PostgreSQL-based Elixir [EventStore](https://github.com/commanded/eventstore) with `Commanded.EventStore.Adapters.EventStore` Adapter.

There is also an [in-memory event store adapter](./in-memory-event-store.md) for **test use only**.

Want to use a different event store? Then you will need to write your own event store provider as described below.

---

## PostgreSQL-based Elixir EventStore

Use `Commanded.EventStore.Adapters.EventStore` to persist events to a PostgreSQL database. As the name implies, this is the adapter for [EventStore](https://github.com/commanded/eventstore), which is open-source event store using PostgreSQL for persistence and implemented in Elixir.

---

## Writing your own event store provider

To use an alternative event store with Commanded you will need to implement the `Commanded.EventStore.Adapter` behaviour. This defines the contract to be implemented by an adapter module to allow an event store to be used with Commanded. Tests to verify an adapter conforms to the behaviour are provided in `test/event_store_adapter`.
