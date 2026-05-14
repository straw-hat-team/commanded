defmodule Commanded.Aggregates.AggregateConcurrencyTest do
  use Commanded.MockEventStoreCase

  alias Commanded.Aggregates.{Aggregate, ExecutionContext}
  alias Commanded.ExampleDomain.{BankAccount, DepositMoneyHandler, OpenAccountHandler}
  alias Commanded.ExampleDomain.BankAccount.Commands.{DepositMoney, OpenAccount}
  alias Commanded.ExampleDomain.BankAccount.Events.MoneyDeposited
  alias Commanded.MockedApp
  alias Commanded.UUID

  describe "concurrency error" do
    setup [:open_account]

    test "should retry command", context do
      %{account_number: account_number} = context

      command = %DepositMoney{
        account_number: account_number,
        transfer_uuid: UUID.uuid4(),
        amount: 100
      }

      context = %ExecutionContext{
        command: command,
        handler: DepositMoneyHandler,
        function: :handle,
        retry_attempts: 1
      }

      concurrent_event =
        build_recorded_event(
          account_number,
          2,
          %MoneyDeposited{
            account_number: account_number,
            transfer_uuid: UUID.uuid4(),
            amount: 500,
            balance: 1_500
          },
          event_type: "Elixir.Commanded.ExampleDomain.BankAccount.Events.MoneyDeposited"
        )

      expect_concurrency_retry_succeeds(account_number, concurrent_event)

      assert {:ok, 3, _events, _aggregate_state} =
               Aggregate.execute(MockedApp, BankAccount, account_number, context)

      assert Aggregate.aggregate_version(MockedApp, BankAccount, account_number) == 3

      assert Aggregate.aggregate_state(MockedApp, BankAccount, account_number) == %BankAccount{
               account_number: account_number,
               balance: 1_600,
               state: :active
             }
    end

    test "should error after too many attempts", %{account_number: account_number} do
      expect_too_many_retry_attempts(account_number)

      command = %DepositMoney{
        account_number: account_number,
        transfer_uuid: UUID.uuid4(),
        amount: 100
      }

      context = %ExecutionContext{
        command: command,
        handler: DepositMoneyHandler,
        function: :handle,
        retry_attempts: 5
      }

      assert {:error, :too_many_attempts} =
               Aggregate.execute(MockedApp, BankAccount, account_number, context)
    end

    defp open_account(_context) do
      account_number = UUID.uuid4()

      expect_open_aggregate(account_number)

      {:ok, ^account_number} =
        Commanded.Aggregates.Supervisor.open_aggregate(MockedApp, BankAccount, account_number)

      command = %OpenAccount{account_number: account_number, initial_balance: 1_000}

      context = %ExecutionContext{
        command: command,
        handler: OpenAccountHandler,
        function: :handle,
        retry_attempts: 1
      }

      {:ok, 1, _events, _aggregate_state} =
        Aggregate.execute(MockedApp, BankAccount, account_number, context)

      [
        account_number: account_number
      ]
    end
  end
end
