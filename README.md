# Commanded

Use Commanded to build your own Event-Sourcing applications.

## References

- [Getting started](guides/Getting%20Started.md)
- [Choosing an event store](guides/Choosing%20an%20Event%20Store.md)
  - [PostgreSQL-based EventStore](guides/Choosing%20an%20Event%20Store.md#postgresql-based-elixir-eventstore)
- [Using Commanded](guides/Usage.md)
  - [Aggregates](guides/Aggregates.md)
    - [Example aggregate](guides/Aggregates.md#example-aggregate)
    - [`Commanded.Aggregate.Multi`](guides/Aggregates.md#using-commandedaggregatemulti-to-return-multiple-events)
    - [Aggregate state snapshots](guides/Aggregates.md#aggregate-state-snapshots)
  - [Commands](guides/Commands.md)
    - [Command handlers](guides/Commands.md#command-handlers)
    - [Command dispatch and routing](guides/Commands.md#command-dispatch-and-routing)
      - [Define aggregate identity](guides/Commands.md#define-aggregate-identity)
      - [Multi-command registration](guides/Commands.md#multi-command-registration)
      - [Dispatch timeouts](guides/Commands.md#timeouts)
      - [Dispatch consistency guarantee](guides/Commands.md#command-dispatch-consistency-guarantee)
      - [Dispatch returning execution result](guides/Commands.md#dispatch-returning-execution-result)
      - [Aggregate lifespan](guides/Commands.md#aggregate-lifespan)
      - [Composite command routers](guides/Commands.md#composite-command-routers)
    - [Middleware](guides/Commands.md#middleware)
      - [Example middleware](guides/Commands.md#example-middleware)
    - [Composite command routers](guides/Commands.md#composite-command-routers)
  - [Events](guides/Events.md)
    - [Domain events](guides/Events.md#domain-events)
    - [Event handlers](guides/Events.md#event-handlers)
      - [Consistency guarantee](guides/Events.md#consistency-guarantee)
      - [Error handling](guides/Events.md#handling-errors)
    - [Upcasting events](guides/Events.md#upcasting-events)
    - [`Commanded.Event.EventId`]: `Commanded.Event.EventId` protocol.
  - [Process managers](guides/Process%20Managers.md)
    - [Example process manager](guides/Process%20Managers.md#example-process-manager)
  - [Supervision](guides/Supervision.md)
  - [Serialization](guides/Serialization.md)
    - [Default JSON serializer](guides/Serialization.md#default-json-serializer)
    - [Configuring JSON serialization](guides/Serialization.md#configuring-json-serialization)
    - [Decoding event structs](guides/Serialization.md#decoding-event-structs)
    - [Using an alternative serialization format](guides/Serialization.md#using-an-alternative-serialization-format)
    - [Customising serialization](guides/Serialization.md#customising-serialization)
  - [Read model projections](guides/Read%20Model%20Projections.md)
- [Deployment](guides/Deployment.md)
  - [Single node deployment](guides/Deployment.md#single-node-deployment)
  - [Multi node cluster deployment](guides/Deployment.md#multi-node-cluster-deployment)
  - [Multi node, but not clustered deployment](guides/Deployment.md#multi-node-but-not-clustered-deployment)
- [Testing with Commanded](guides/Testing.md)
- [Used in production?](#used-in-production)
- [Example application](#example-application)
- [Learn Commanded in 20 minutes](#learn-commanded-in-20-minutes)
- [Choosing an event store provider](guides/Choosing%20an%20Event%20Store.md#writing-your-own-event-store-provider)
- [Tooling](https://github.com/commanded/commanded/wiki/Tooling)
- [Contributing](./CONTRIBUTING.md)
- [Changelog](./CHANGELOG.md)

You can use Commanded with one of the following event stores for persistence:

- [EventStore](https://github.com/commanded/eventstore) - Elixir library using Postgres for persistence.
- [In-memory event store](https://github.com/commanded/commanded/wiki/In-memory-event-store) - included for test use only.
