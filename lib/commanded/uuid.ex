defmodule Commanded.UUID do
  @moduledoc """
  Configurable UUID generation for correlation and causation IDs.

  By default uses `Uniq.UUID`. Configure an alternative provider:

      config :commanded, Commanded.UUID, module: MyApp.CustomUUID

  Your custom module must provide a `uuid4/0` function.
  """

  # Get the configured UUID module at compile time, fallback to Uniq.UUID
  @uuid_mod Application.compile_env(:commanded, [__MODULE__, :module], Uniq.UUID)

  @doc """
  Generates a UUID using the configured provider (defaults to `Uniq.UUID`).
  """
  defdelegate uuid4, to: @uuid_mod
end
