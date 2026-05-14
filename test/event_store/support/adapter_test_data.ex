defmodule Commanded.EventStore.AdapterTestData do
  alias Commanded.Event.Mapper
  alias Commanded.EventStore.SnapshotData
  alias Commanded.EventStore.TypeProvider
  alias Commanded.ExampleDomain.BankAccount
  alias Commanded.ExampleDomain.BankAccount.Events.{BankAccountOpened, MoneyDeposited}
  alias Commanded.Helpers.EventFactory
  alias Commanded.UUID

  def build_opened_event(opts \\ []) do
    %BankAccountOpened{
      account_number: Keyword.get(opts, :account_number, 1),
      initial_balance: Keyword.get(opts, :initial_balance, 1_000)
    }
  end

  def build_opened_event_data(opts \\ []) do
    correlation_id = Keyword.get_lazy(opts, :correlation_id, &UUID.uuid4/0)
    causation_id = Keyword.get_lazy(opts, :causation_id, &UUID.uuid4/0)
    metadata = Keyword.get(opts, :metadata, default_metadata())

    build_opened_event(opts)
    |> Mapper.map_to_event_data(
      correlation_id: correlation_id,
      causation_id: causation_id,
      metadata: metadata
    )
  end

  def build_opened_events(count, opts \\ []) do
    correlation_id = Keyword.get_lazy(opts, :correlation_id, &UUID.uuid4/0)
    causation_id = Keyword.get_lazy(opts, :causation_id, &UUID.uuid4/0)
    initial_balance = Keyword.get(opts, :initial_balance, 1_000)
    metadata = Keyword.get(opts, :metadata, default_metadata())
    start_account_number = Keyword.get(opts, :start_account_number, 1)

    start_account_number..(start_account_number + count - 1)
    |> Enum.map(fn account_number ->
      build_opened_event(account_number: account_number, initial_balance: initial_balance)
    end)
    |> Mapper.map_to_event_data(
      correlation_id: correlation_id,
      causation_id: causation_id,
      metadata: metadata
    )
  end

  def build_deposited_event(opts \\ []) do
    transfer_uuid = Keyword.get_lazy(opts, :transfer_uuid, &UUID.uuid4/0)

    %MoneyDeposited{
      account_number: Keyword.get(opts, :account_number, 1),
      transfer_uuid: transfer_uuid,
      amount: Keyword.get(opts, :amount, 250),
      balance: Keyword.get(opts, :balance, 1_250)
    }
  end

  def build_deposited_event_data(opts \\ []) do
    correlation_id = Keyword.get_lazy(opts, :correlation_id, &UUID.uuid4/0)
    causation_id = Keyword.get_lazy(opts, :causation_id, &UUID.uuid4/0)
    metadata = Keyword.get(opts, :metadata, default_metadata())

    build_deposited_event(opts)
    |> Mapper.map_to_event_data(
      correlation_id: correlation_id,
      causation_id: causation_id,
      metadata: metadata
    )
  end

  def build_deposit_event(account_number, opts \\ []) do
    build_deposited_event_data(Keyword.put(opts, :account_number, account_number))
  end

  def build_recorded_events(events, initial_event_number \\ 1, opts \\ []) do
    EventFactory.map_to_recorded_events(events, initial_event_number, opts)
  end

  def build_snapshot_data(source_version, opts \\ []) do
    created_at = Keyword.get(opts, :created_at, DateTime.utc_now())
    metadata = Keyword.get(opts, :metadata, nil)
    source_uuid = Keyword.get_lazy(opts, :source_uuid, &UUID.uuid4/0)

    account_state =
      Keyword.get_lazy(opts, :data, fn ->
        %BankAccount{
          account_number: Keyword.get(opts, :account_number, source_version),
          state: :active,
          balance: Keyword.get(opts, :balance, 1_000)
        }
      end)

    %SnapshotData{
      source_uuid: source_uuid,
      source_version: source_version,
      source_type: TypeProvider.to_string(account_state),
      data: account_state,
      metadata: metadata,
      created_at: created_at
    }
  end

  def default_metadata do
    %{
      "channel" => "web",
      "request" => %{
        "actor_id" => "customer-123",
        "actor_type" => "customer"
      }
    }
  end
end
