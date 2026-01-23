defmodule Commanded.TestSupport.TestDomain do
  @moduledoc """
  Test support domain structs for integration tests.
  """

  defmodule OpenAccount do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:account_id, :owner, :initial_balance]
  end

  defmodule DepositMoney do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:account_id, :amount]
  end

  defmodule WithdrawMoney do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:account_id, :amount]
  end

  defmodule AccountOpened do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:account_id, :owner, :initial_balance]
  end

  defmodule MoneyDeposited do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:account_id, :amount, :new_balance]
  end

  defmodule MoneyWithdrawn do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:account_id, :amount, :new_balance]
  end

  defmodule Account do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:account_id, :owner, :balance, :status]
  end
end
