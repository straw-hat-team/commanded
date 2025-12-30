defmodule Commanded.OpenTelemetry do
  @moduledoc """
  OpenTelemetry integration for Commanded.

  Provides automatic distributed tracing of Commanded operations using OpenTelemetry.

  ## Usage

  Call `setup/0` in your application's `start/2` callback:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          Commanded.OpenTelemetry.setup()

          children = [MyApp.CommandedApp]
          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  ## Trace Context Propagation

  Add the middleware to your command router to propagate trace context to event handlers:

      defmodule MyApp.Router do
        use Commanded.Commands.Router

        middleware Commanded.Middleware.TraceContextPropagator

        # ... your command routes
      end

  ## Types

  See `t:span_relationship/0` for available span relationship modes.
  """

  alias Commanded.OpenTelemetry.EventHandler

  @typedoc """
  Determines how event handler spans relate to command dispatch spans.

  * `:link` - Create span links to the original command dispatch (default).
    Best for event-driven architectures where events are processed independently.
  * `:child` - Attach event handler spans as children of the command span.
    Best when you want a single trace tree for the entire command lifecycle.
  * `:none` - No span propagation between commands and event handlers.
    Best when events should start fresh traces.
  """
  @type span_relationship :: :link | :child | :none

  @nimble_schema NimbleOptions.new!(
                   event_handler: [
                     type:
                       {:or,
                        [
                          {:in, [:disabled]},
                          keyword_list: [
                            span_relationship: [
                              type: {:in, [:link, :child, :none]},
                              type_doc: "`t:span_relationship/0`",
                              default: :link
                            ]
                          ]
                        ]},
                     default: [],
                     doc: "Event handler tracing configuration. Use `:disabled` to disable."
                   ]
                 )

  @doc """
  Set up OpenTelemetry tracing for Commanded.

  Attaches telemetry handlers to Commanded events and creates OpenTelemetry spans.

  ## Options

  #{NimbleOptions.docs(@nimble_schema)}

  ## Examples

      # Default setup (uses :link relationship)
      Commanded.OpenTelemetry.setup()

      # Disable event handler tracing
      Commanded.OpenTelemetry.setup(event_handler: :disabled)

      # Use parent-child relationships for event handlers
      Commanded.OpenTelemetry.setup(event_handler: [span_relationship: :child])

  """
  @spec setup(keyword()) :: :ok
  def setup(opts \\ []) do
    opts = NimbleOptions.validate!(opts, @nimble_schema)

    case opts[:event_handler] do
      :disabled -> :ok
      config -> EventHandler.setup(config)
    end
  end
end
