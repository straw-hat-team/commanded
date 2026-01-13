defprotocol Commanded.Aggregate.Identity do
  @moduledoc """
  Protocol to convert an aggregate identity to a stream ID string.

  Any module that implements this protocol can be used for an aggregate's
  identity. By default, this falls back to using the `String.Chars` protocol,
  which includes the following Elixir built-in types: strings, integers, floats,
  atoms, and lists.

  ## Example

      defmodule AccountNumber do
        defstruct [:branch, :account_number]

        defimpl Commanded.Aggregate.Identity do
          def to_stream_id(%AccountNumber{branch: branch, account_number: account_number}) do
            branch <> ":" <> account_number
          end
        end
      end

  The custom identity will be converted to a string during command dispatch.
  This is used as the aggregate's identity and determines the stream to append
  its events in the event store.
  """

  @fallback_to_any true

  @doc """
  Convert the aggregate identity to a stream ID string.
  """
  @spec to_stream_id(t) :: String.t()
  def to_stream_id(identity)
end

defimpl Commanded.Aggregate.Identity, for: Any do
  @moduledoc """
  Default implementation falling back to `String.Chars` protocol.

  This ensures backwards compatibility with existing code that implements
  `String.Chars` for custom identity types.
  """

  def to_stream_id(identity) do
    to_string(identity)
  end
end
