defmodule Commanded.TestSupport.Factory do
  alias Commanded.EventStore.RecordedEvent
  alias Commanded.TestSupport.TestDomain
  alias Commanded.UUID

  def build_open_account(opts \\ []) do
    defaults = [
      account_id: UUID.uuid4(),
      owner: "Test User",
      initial_balance: 1000
    ]

    opts = Keyword.merge(defaults, opts)

    %TestDomain.OpenAccount{
      account_id: Keyword.fetch!(opts, :account_id),
      owner: Keyword.fetch!(opts, :owner),
      initial_balance: Keyword.fetch!(opts, :initial_balance)
    }
  end

  def build_deposit_money(opts \\ []) do
    defaults = [
      account_id: UUID.uuid4(),
      amount: 100
    ]

    opts = Keyword.merge(defaults, opts)

    %TestDomain.DepositMoney{
      account_id: Keyword.fetch!(opts, :account_id),
      amount: Keyword.fetch!(opts, :amount)
    }
  end

  def build_withdraw_money(opts \\ []) do
    defaults = [
      account_id: UUID.uuid4(),
      amount: 50
    ]

    opts = Keyword.merge(defaults, opts)

    %TestDomain.WithdrawMoney{
      account_id: Keyword.fetch!(opts, :account_id),
      amount: Keyword.fetch!(opts, :amount)
    }
  end

  def build_account_opened_event(opts \\ []) do
    defaults = [
      account_id: UUID.uuid4(),
      owner: "Test User",
      initial_balance: 1000
    ]

    opts = Keyword.merge(defaults, opts)

    %TestDomain.AccountOpened{
      account_id: Keyword.fetch!(opts, :account_id),
      owner: Keyword.fetch!(opts, :owner),
      initial_balance: Keyword.fetch!(opts, :initial_balance)
    }
  end

  def build_money_deposited_event(opts \\ []) do
    defaults = [
      account_id: UUID.uuid4(),
      amount: 100,
      new_balance: 1100
    ]

    opts = Keyword.merge(defaults, opts)

    %TestDomain.MoneyDeposited{
      account_id: Keyword.fetch!(opts, :account_id),
      amount: Keyword.fetch!(opts, :amount),
      new_balance: Keyword.fetch!(opts, :new_balance)
    }
  end

  def build_money_withdrawn_event(opts \\ []) do
    defaults = [
      account_id: UUID.uuid4(),
      amount: 50,
      new_balance: 950
    ]

    opts = Keyword.merge(defaults, opts)

    %TestDomain.MoneyWithdrawn{
      account_id: Keyword.fetch!(opts, :account_id),
      amount: Keyword.fetch!(opts, :amount),
      new_balance: Keyword.fetch!(opts, :new_balance)
    }
  end

  def build_account(opts \\ []) do
    defaults = [
      account_id: UUID.uuid4(),
      owner: "Test User",
      balance: 0,
      status: :active
    ]

    opts = Keyword.merge(defaults, opts)

    %TestDomain.Account{
      account_id: Keyword.fetch!(opts, :account_id),
      owner: Keyword.fetch!(opts, :owner),
      balance: Keyword.fetch!(opts, :balance),
      status: Keyword.fetch!(opts, :status)
    }
  end

  def build_recorded_event(opts \\ []) do
    account_id = Keyword.get(opts, :account_id, UUID.uuid4())

    default_data = %TestDomain.AccountOpened{
      account_id: account_id,
      owner: "Test",
      initial_balance: 1000
    }

    defaults = [
      event_id: UUID.uuid4(),
      event_number: 1,
      stream_id: "account-#{account_id}",
      stream_version: 1,
      causation_id: UUID.uuid4(),
      correlation_id: UUID.uuid4(),
      event_type: "Elixir.Commanded.TestSupport.TestDomain.AccountOpened",
      data: default_data,
      created_at: DateTime.utc_now(),
      metadata: %{}
    ]

    opts = Keyword.merge(defaults, opts)

    %RecordedEvent{
      event_id: Keyword.fetch!(opts, :event_id),
      event_number: Keyword.fetch!(opts, :event_number),
      stream_id: Keyword.fetch!(opts, :stream_id),
      stream_version: Keyword.fetch!(opts, :stream_version),
      causation_id: Keyword.fetch!(opts, :causation_id),
      correlation_id: Keyword.fetch!(opts, :correlation_id),
      event_type: Keyword.fetch!(opts, :event_type),
      data: Keyword.fetch!(opts, :data),
      created_at: Keyword.fetch!(opts, :created_at),
      metadata: Keyword.fetch!(opts, :metadata)
    }
  end

  def build_telemetry_start_measurements(opts \\ []) do
    defaults = [
      system_time: System.monotonic_time(:nanosecond)
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      system_time: Keyword.fetch!(opts, :system_time)
    }
  end

  def build_telemetry_stop_measurements(opts \\ []) do
    defaults = [
      duration: 10_000_000
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      duration: Keyword.fetch!(opts, :duration)
    }
  end

  def build_telemetry_exception_measurements(opts \\ []) do
    defaults = [
      duration: 5_000_000
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      duration: Keyword.fetch!(opts, :duration)
    }
  end

  def build_event_handler_metadata(opts \\ []) do
    recorded_event =
      Keyword.get_lazy(opts, :recorded_event, fn ->
        build_recorded_event()
      end)

    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      handler_name: "AccountEventHandler",
      handler_module: Keyword.get(opts, :handler_module, MockHandler),
      handler_state: nil,
      context: %{},
      recorded_event: recorded_event
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      handler_name: Keyword.fetch!(opts, :handler_name),
      handler_module: Keyword.fetch!(opts, :handler_module),
      handler_state: Keyword.fetch!(opts, :handler_state),
      context: Keyword.fetch!(opts, :context),
      recorded_event: Keyword.fetch!(opts, :recorded_event)
    }
  end

  def build_batch_handler_metadata(opts \\ []) do
    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      handler_name: "BatchAccountEventHandler",
      handler_module: Keyword.get(opts, :handler_module, MockBatchHandler),
      handler_state: nil,
      context: %{},
      first_event_id: UUID.uuid4(),
      last_event_id: UUID.uuid4(),
      event_count: 5,
      recorded_event: nil
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      handler_name: Keyword.fetch!(opts, :handler_name),
      handler_module: Keyword.fetch!(opts, :handler_module),
      handler_state: Keyword.fetch!(opts, :handler_state),
      context: Keyword.fetch!(opts, :context),
      first_event_id: Keyword.fetch!(opts, :first_event_id),
      last_event_id: Keyword.fetch!(opts, :last_event_id),
      event_count: Keyword.fetch!(opts, :event_count),
      recorded_event: Keyword.fetch!(opts, :recorded_event)
    }
  end

  def build_exception_metadata(opts \\ []) do
    recorded_event =
      Keyword.get_lazy(opts, :recorded_event, fn ->
        build_recorded_event()
      end)

    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      handler_name: "AccountEventHandler",
      handler_module: Keyword.get(opts, :handler_module, MockHandler),
      handler_state: nil,
      context: %{},
      recorded_event: recorded_event,
      kind: :error,
      reason: %RuntimeError{message: "Test error"},
      stacktrace: []
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      handler_name: Keyword.fetch!(opts, :handler_name),
      handler_module: Keyword.fetch!(opts, :handler_module),
      handler_state: Keyword.fetch!(opts, :handler_state),
      context: Keyword.fetch!(opts, :context),
      recorded_event: Keyword.fetch!(opts, :recorded_event),
      kind: Keyword.fetch!(opts, :kind),
      reason: Keyword.fetch!(opts, :reason),
      stacktrace: Keyword.fetch!(opts, :stacktrace)
    }
  end

  def build_telemetry_event(event_type, opts \\ [])

  def build_telemetry_event(:start, opts) do
    measurements = build_telemetry_start_measurements()
    metadata = build_event_handler_metadata(opts)
    event_name = [:commanded, :event, :handle, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:stop, opts) do
    measurements = build_telemetry_stop_measurements()
    metadata = build_event_handler_metadata(opts)
    event_name = [:commanded, :event, :handle, :stop]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:exception, opts) do
    measurements = build_telemetry_exception_measurements()
    metadata = build_exception_metadata(opts)
    event_name = [:commanded, :event, :handle, :exception]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:batch_start, opts) do
    measurements = build_telemetry_start_measurements()
    metadata = build_batch_handler_metadata(opts)
    event_name = [:commanded, :event, :batch, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:batch_stop, opts) do
    measurements = build_telemetry_stop_measurements()
    metadata = build_batch_handler_metadata(opts)
    event_name = [:commanded, :event, :batch, :stop]

    {event_name, measurements, metadata}
  end

  def build_account_scenario(opts \\ []) do
    account_id = Keyword.get(opts, :account_id, UUID.uuid4())
    owner = Keyword.get(opts, :owner, "Test User")
    initial_balance = Keyword.get(opts, :initial_balance, 1000)

    command =
      build_open_account(
        account_id: account_id,
        owner: owner,
        initial_balance: initial_balance
      )

    event =
      build_account_opened_event(
        account_id: account_id,
        owner: owner,
        initial_balance: initial_balance
      )

    recorded_event =
      build_recorded_event(
        account_id: account_id,
        event_type: "Elixir.Commanded.TestSupport.TestDomain.AccountOpened",
        data: event,
        stream_id: "account-#{account_id}"
      )

    %{
      command: command,
      event: event,
      recorded_event: recorded_event,
      account_id: account_id
    }
  end

  def build_deposit_scenario(opts \\ []) do
    account_id = Keyword.get(opts, :account_id, UUID.uuid4())
    amount = Keyword.get(opts, :amount, 100)
    current_balance = Keyword.get(opts, :current_balance, 1000)

    command =
      build_deposit_money(
        account_id: account_id,
        amount: amount
      )

    event =
      build_money_deposited_event(
        account_id: account_id,
        amount: amount,
        new_balance: current_balance + amount
      )

    recorded_event =
      build_recorded_event(
        account_id: account_id,
        event_type: "Elixir.Commanded.TestSupport.TestDomain.MoneyDeposited",
        data: event,
        stream_id: "account-#{account_id}",
        event_number: 2
      )

    %{
      command: command,
      event: event,
      recorded_event: recorded_event,
      account_id: account_id
    }
  end
end
