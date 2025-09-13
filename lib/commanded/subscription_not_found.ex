defmodule Commanded.SubscriptionNotFound do
  @moduledoc """
  Exception raised when attempting to access a subscription that doesn't exist.
  """
  defexception [:subscription_name, :message]

  @type t :: %__MODULE__{
          subscription_name: String.t() | nil,
          message: String.t()
        }

  def exception(subscription_name) when is_binary(subscription_name) do
    %__MODULE__{
      subscription_name: subscription_name,
      message: "Subscription '#{subscription_name}' not found"
    }
  end

  def exception(opts) when is_list(opts) do
    subscription_name = Keyword.get(opts, :subscription_name)
    message = Keyword.get(opts, :message, build_message(subscription_name))

    %__MODULE__{
      subscription_name: subscription_name,
      message: message
    }
  end

  def exception(_) do
    %__MODULE__{
      subscription_name: nil,
      message: "Subscription not found"
    }
  end

  @doc """
  Factory function to create a SubscriptionNotFound exception.
  """
  def new(subscription_name \\ nil) do
    exception(subscription_name)
  end

  defp build_message(nil), do: "Subscription not found"
  defp build_message(name), do: "Subscription '#{name}' not found"
end
