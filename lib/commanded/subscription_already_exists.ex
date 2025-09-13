defmodule Commanded.SubscriptionAlreadyExists do
  @moduledoc """
  Exception raised when attempting to create a subscription that already exists.
  """
  defexception [:subscription_name, :message]

  @type t :: %__MODULE__{
          subscription_name: String.t() | nil,
          message: String.t()
        }

  def exception(subscription_name) when is_binary(subscription_name) do
    %__MODULE__{
      subscription_name: subscription_name,
      message: "Subscription '#{subscription_name}' already exists"
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
      message: "Subscription already exists"
    }
  end

  @doc """
  Factory function to create a SubscriptionAlreadyExists exception.
  """
  def new(subscription_name \\ nil) do
    exception(subscription_name)
  end

  defp build_message(nil), do: "Subscription already exists"
  defp build_message(name), do: "Subscription '#{name}' already exists"
end
