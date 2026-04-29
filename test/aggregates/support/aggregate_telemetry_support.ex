defmodule Commanded.Aggregates.AggregateTelemetrySupport do
  @moduledoc false

  defmodule Commands do
    defmodule Ok do
      defstruct [:message]
    end

    defmodule Error do
      defstruct [:message]
    end

    defmodule RaiseException do
      defstruct [:message]
    end
  end

  defmodule Event do
    @derive Jason.Encoder
    defstruct [:message]
  end

  defmodule ExampleAggregate do
    alias Commanded.Aggregates.AggregateTelemetrySupport.Commands.{Error, Ok, RaiseException}
    alias Commanded.Aggregates.AggregateTelemetrySupport.Event

    defstruct [:message]

    def execute(%ExampleAggregate{}, %Ok{message: message}), do: %Event{message: message}
    def execute(%ExampleAggregate{}, %Error{message: message}), do: {:error, message}
    def execute(%ExampleAggregate{}, %RaiseException{message: message}), do: raise(message)

    def apply(%ExampleAggregate{}, %Event{message: message}),
      do: %ExampleAggregate{message: message}
  end
end
