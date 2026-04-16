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

## Override Returned Error Status

You can override the span status used for returned `:stop` errors on application
dispatch and aggregate execution spans:

```elixir
Commanded.OpenTelemetry.setup(
  application: [
    error_status: fn
      _event_name, _measurements, %{error: :validation_failed}, _config -> :unset
      _event_name, _measurements, _meta, _config -> :error
    end
  ],
  aggregate: [
    error_status: fn
      _event_name, _measurements, %{error: :validation_failed}, _config -> :unset
      _event_name, _measurements, _meta, _config -> :error
    end
  ]
)
```

The callback receives the telemetry event name first, then the stop measurements,
then the full telemetry metadata map, and finally the instrumentation config. It
may return:

- `:unset`, `:ok`, or `:error`
- `nil` to leave the status unset

When the callback returns `:error`, Commanded derives the status description from
the returned error using `Commanded.OpenTelemetry.Helpers.format_error/1`.

Exceptions are not routed through this callback; they continue to record
exception events and set span status to error.
