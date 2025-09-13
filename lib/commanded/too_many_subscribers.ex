defmodule Commanded.TooManySubscribers do
  @moduledoc """
  Exception raised when attempting to add more subscribers than allowed.
  """
  defexception [:max_subscribers, :current_count, :subscription_name, :message]

  @type t :: %__MODULE__{
          max_subscribers: integer() | nil,
          current_count: integer() | nil,
          subscription_name: String.t() | nil,
          message: String.t()
        }

  def exception(opts) when is_list(opts) do
    max_subscribers = Keyword.get(opts, :max_subscribers)
    current_count = Keyword.get(opts, :current_count)
    subscription_name = Keyword.get(opts, :subscription_name)
    message = Keyword.get(opts, :message, build_message(max_subscribers, current_count, subscription_name))

    %__MODULE__{
      max_subscribers: max_subscribers,
      current_count: current_count,
      subscription_name: subscription_name,
      message: message
    }
  end

  def exception(_) do
    %__MODULE__{
      max_subscribers: nil,
      current_count: nil,
      subscription_name: nil,
      message: "Too many subscribers"
    }
  end

  defp build_message(max, current, name) do
    base = "Too many subscribers"
    name_part = if name, do: " for subscription '#{name}'", else: ""

    count_part =
      case {current, max} do
        {nil, nil} -> ""
        {current, nil} -> " (current: #{current})"
        {nil, max} -> " (max: #{max})"
        {current, max} -> " (current: #{current}, max: #{max})"
      end

    base <> name_part <> count_part
  end

  @doc """
  Factory function to create a TooManySubscribers exception.
  """
  def new(opts \\ []) do
    exception(opts)
  end
end
