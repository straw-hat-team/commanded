# How to Set Up OpenTelemetry Tracing

## Enable Event Handler Tracing

Call `Commanded.OpenTelemetry.setup/0` in your application's `start/2` callback:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    Commanded.OpenTelemetry.setup()

    children = [
      MyApp.CommandedApp
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## Enable Trace Context Propagation

Add the middleware to your command router:

```elixir
defmodule MyApp.Router do
  use Commanded.Commands.Router

  middleware Commanded.Middleware.TraceContextPropagator

  dispatch CreateAccount,
    to: AccountHandler,
    aggregate: Account,
    identity: :account_id
end
```

## Configure Span Relationships

Choose one of the following span relationship modes when calling `setup/1`:

```elixir
# Create span links to the original command dispatch (default)
Commanded.OpenTelemetry.setup(event_handler: [span_relationship: :link])

# Make event handler spans children of the command span
Commanded.OpenTelemetry.setup(event_handler: [span_relationship: :child])

# No span propagation between commands and event handlers
Commanded.OpenTelemetry.setup(event_handler: [span_relationship: :none])
```

Note: `setup/1` should only be called once during application startup.

## Disable Event Handler Tracing

```elixir
Commanded.OpenTelemetry.setup(event_handler: :disabled)
```

