defmodule Commanded.TestSupport.Factory do
  alias Commanded.Aggregates.ExecutionContext
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

  def build_recorded_event(name_or_opts \\ [])

  def build_recorded_event(:account_projector) do
    build_recorded_event(:account_projector, [])
  end

  def build_recorded_event(:transaction_projector) do
    build_recorded_event(:transaction_projector, [])
  end

  def build_recorded_event(opts) when is_list(opts) do
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

  def build_recorded_event(:account_projector, opts) do
    aggregate_uuid = Keyword.get(opts, :aggregate_uuid, UUID.uuid4())

    build_recorded_event(
      Keyword.merge(
        [
          event_type: "Elixir.MyApp.Events.AccountOpened",
          stream_id: "BankAccount-#{aggregate_uuid}"
        ],
        opts
      )
    )
  end

  def build_recorded_event(:transaction_projector, opts) do
    aggregate_uuid = Keyword.get(opts, :aggregate_uuid, UUID.uuid4())

    build_recorded_event(
      Keyword.merge(
        [
          event_type: "Elixir.MyApp.Events.TransactionCreated",
          stream_id: "Transaction-#{aggregate_uuid}"
        ],
        opts
      )
    )
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

  def build_event_handler_metadata(name_or_opts \\ [])

  def build_event_handler_metadata(:account_projector) do
    build_event_handler_metadata(:account_projector, [])
  end

  def build_event_handler_metadata(:transaction_projector) do
    build_event_handler_metadata(:transaction_projector, [])
  end

  def build_event_handler_metadata(opts) when is_list(opts) do
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

  def build_event_handler_metadata(:account_projector, opts) do
    recorded_event =
      Keyword.get_lazy(opts, :recorded_event, fn ->
        build_recorded_event(:account_projector, opts)
      end)

    build_event_handler_metadata(
      Keyword.merge(
        [
          application: MyApp.CommandedApp,
          handler_name: "MyApp.Projectors.AccountProjector",
          handler_module: MyApp.Projectors.AccountProjector,
          recorded_event: recorded_event
        ],
        opts
      )
    )
  end

  def build_event_handler_metadata(:transaction_projector, opts) do
    recorded_event =
      Keyword.get_lazy(opts, :recorded_event, fn ->
        build_recorded_event(:transaction_projector, opts)
      end)

    build_event_handler_metadata(
      Keyword.merge(
        [
          application: MyApp.CommandedApp,
          handler_name: "MyApp.Projectors.TransactionProjector",
          handler_module: MyApp.Projectors.TransactionProjector,
          recorded_event: recorded_event
        ],
        opts
      )
    )
  end

  def build_batch_handler_metadata(name_or_opts \\ [])

  def build_batch_handler_metadata(:account_projector) do
    build_batch_handler_metadata(:account_projector, [])
  end

  def build_batch_handler_metadata(:transaction_projector) do
    build_batch_handler_metadata(:transaction_projector, [])
  end

  def build_batch_handler_metadata(opts) when is_list(opts) do
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

    base = %{
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

    # Add optional fields
    base
    |> maybe_put(:error, opts)
    |> maybe_put_exception_fields(opts)
  end

  defp maybe_put(map, key, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Map.put(map, key, value)
      :error -> map
    end
  end

  # When reason is provided, default kind to :error and stacktrace to []
  defp maybe_put_exception_fields(map, opts) do
    case Keyword.fetch(opts, :reason) do
      {:ok, reason} ->
        map
        |> Map.put(:kind, Keyword.get(opts, :kind, :error))
        |> Map.put(:reason, reason)
        |> Map.put(:stacktrace, Keyword.get(opts, :stacktrace, []))

      :error ->
        map
    end
  end

  def build_batch_handler_metadata(:account_projector, opts) do
    build_batch_handler_metadata(
      Keyword.merge(
        [
          application: MyApp.CommandedApp,
          handler_name: "MyApp.Projectors.AccountProjector",
          handler_module: MyApp.Projectors.AccountProjector,
          handler_state: %{processed_count: 0},
          event_count: 10
        ],
        opts
      )
    )
  end

  def build_batch_handler_metadata(:transaction_projector, opts) do
    build_batch_handler_metadata(
      Keyword.merge(
        [
          application: MyApp.CommandedApp,
          handler_name: "MyApp.Projectors.TransactionProjector",
          handler_module: MyApp.Projectors.TransactionProjector,
          handler_state: %{processed_count: 0},
          event_count: 10
        ],
        opts
      )
    )
  end

  def build_exception_metadata(name_or_opts \\ [])

  def build_exception_metadata(:account_projector) do
    build_exception_metadata(:account_projector, [])
  end

  def build_exception_metadata(:transaction_projector) do
    build_exception_metadata(:transaction_projector, [])
  end

  def build_exception_metadata(opts) when is_list(opts) do
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

  def build_exception_metadata(:account_projector, opts) do
    recorded_event =
      Keyword.get_lazy(opts, :recorded_event, fn ->
        build_recorded_event(:account_projector, opts)
      end)

    build_exception_metadata(
      Keyword.merge(
        [
          application: MyApp.CommandedApp,
          handler_name: "MyApp.Projectors.AccountProjector",
          handler_module: MyApp.Projectors.AccountProjector,
          recorded_event: recorded_event,
          reason: %KeyError{key: :account_number, term: %{balance: 100}},
          stacktrace: [
            {MyApp.Projectors.AccountProjector, :handle, 2,
             [file: ~c"lib/my_app/projectors/account_projector.ex", line: 45]},
            {Commanded.Event.Handler, :delegate_event_to_handler, 2,
             [file: ~c"lib/commanded/event/handler.ex", line: 1192]}
          ]
        ],
        opts
      )
    )
  end

  def build_exception_metadata(:transaction_projector, opts) do
    recorded_event =
      Keyword.get_lazy(opts, :recorded_event, fn ->
        build_recorded_event(:transaction_projector, opts)
      end)

    build_exception_metadata(
      Keyword.merge(
        [
          application: MyApp.CommandedApp,
          handler_name: "MyApp.Projectors.TransactionProjector",
          handler_module: MyApp.Projectors.TransactionProjector,
          recorded_event: recorded_event
        ],
        opts
      )
    )
  end

  def build_application_dispatch_metadata(opts \\ []) do
    causation_id = Keyword.get(opts, :causation_id, UUID.uuid4())
    correlation_id = Keyword.get(opts, :correlation_id, UUID.uuid4())

    command =
      Keyword.get_lazy(opts, :command, fn ->
        build_open_account()
      end)

    execution_context =
      Keyword.get_lazy(opts, :execution_context, fn ->
        %ExecutionContext{
          command: command,
          causation_id: causation_id,
          correlation_id: correlation_id,
          handler: Keyword.get(opts, :handler, TestDomain.Account),
          function: Keyword.get(opts, :function, :execute),
          metadata: Keyword.get(opts, :metadata, %{})
        }
      end)

    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      execution_context: execution_context
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      execution_context: Keyword.fetch!(opts, :execution_context),
      error: nil
    }
  end

  def build_application_dispatch_stop_metadata(opts \\ []) do
    base = build_application_dispatch_metadata(opts)

    Map.merge(base, %{
      error: Keyword.get(opts, :error, nil)
    })
  end

  def build_application_dispatch_exception_metadata(opts \\ []) do
    base = build_application_dispatch_metadata(opts)

    Map.merge(base, %{
      kind: Keyword.get(opts, :kind, :error),
      reason: Keyword.get(opts, :reason, %RuntimeError{message: "Test error"}),
      stacktrace: Keyword.get(opts, :stacktrace, [])
    })
  end

  def build_aggregate_execute_metadata(opts \\ []) do
    aggregate_uuid = Keyword.get(opts, :aggregate_uuid, UUID.uuid4())

    command =
      Keyword.get_lazy(opts, :command, fn ->
        build_open_account(account_id: aggregate_uuid)
      end)

    execution_context =
      Keyword.get_lazy(opts, :execution_context, fn ->
        %{
          command: command,
          causation_id: Keyword.get(opts, :causation_id, UUID.uuid4()),
          correlation_id: Keyword.get(opts, :correlation_id, UUID.uuid4()),
          handler: Keyword.get(opts, :handler, TestDomain.Account),
          function: Keyword.get(opts, :function, :execute),
          metadata: Keyword.get(opts, :metadata, %{})
        }
      end)

    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      aggregate_uuid: aggregate_uuid,
      aggregate_state: Keyword.get(opts, :aggregate_state, %{}),
      aggregate_version: Keyword.get(opts, :aggregate_version, 0),
      caller: Keyword.get(opts, :caller, self()),
      execution_context: execution_context
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      aggregate_uuid: Keyword.fetch!(opts, :aggregate_uuid),
      aggregate_state: Keyword.fetch!(opts, :aggregate_state),
      aggregate_version: Keyword.fetch!(opts, :aggregate_version),
      caller: Keyword.fetch!(opts, :caller),
      execution_context: Keyword.fetch!(opts, :execution_context)
    }
  end

  def build_aggregate_execute_stop_metadata(opts \\ []) do
    base = build_aggregate_execute_metadata(opts)

    Map.merge(base, %{
      events: Keyword.get(opts, :events, []),
      error: Keyword.get(opts, :error, nil)
    })
  end

  def build_aggregate_execute_exception_metadata(opts \\ []) do
    base = build_aggregate_execute_metadata(opts)

    Map.merge(base, %{
      kind: Keyword.get(opts, :kind, :error),
      reason: Keyword.get(opts, :reason, %RuntimeError{message: "Test error"}),
      stacktrace: Keyword.get(opts, :stacktrace, [])
    })
  end

  def build_aggregate_populate_metadata(opts \\ []) do
    aggregate_uuid = Keyword.get(opts, :aggregate_uuid, UUID.uuid4())

    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      aggregate_uuid: aggregate_uuid,
      aggregate_state: Keyword.get(opts, :aggregate_state, %{}),
      aggregate_version: Keyword.get(opts, :aggregate_version, 0)
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      aggregate_uuid: Keyword.fetch!(opts, :aggregate_uuid),
      aggregate_state: Keyword.fetch!(opts, :aggregate_state),
      aggregate_version: Keyword.fetch!(opts, :aggregate_version)
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

  def build_telemetry_event(:aggregate_start, opts) do
    measurements = build_telemetry_start_measurements()
    metadata = build_aggregate_execute_metadata(opts)
    event_name = [:commanded, :aggregate, :execute, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:aggregate_stop, opts) do
    measurements = build_telemetry_stop_measurements()
    metadata = build_aggregate_execute_stop_metadata(opts)
    event_name = [:commanded, :aggregate, :execute, :stop]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:aggregate_exception, opts) do
    measurements = build_telemetry_exception_measurements()
    metadata = build_aggregate_execute_exception_metadata(opts)
    event_name = [:commanded, :aggregate, :execute, :exception]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:application_dispatch_start, opts) do
    measurements = build_telemetry_start_measurements()
    metadata = build_application_dispatch_metadata(opts)
    event_name = [:commanded, :application, :dispatch, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:application_dispatch_stop, opts) do
    measurements = build_telemetry_stop_measurements()
    metadata = build_application_dispatch_stop_metadata(opts)
    event_name = [:commanded, :application, :dispatch, :stop]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:application_dispatch_exception, opts) do
    measurements = build_telemetry_exception_measurements()
    metadata = build_application_dispatch_exception_metadata(opts)
    event_name = [:commanded, :application, :dispatch, :exception]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_append_to_stream_start, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_751_180_934_041),
      system_time: Keyword.get(opts, :system_time, 1_769_132_756_438_728_125)
    }

    metadata = build_event_store_append_to_stream_metadata(opts)
    event_name = [:commanded, :event_store, :append_to_stream, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_append_to_stream_stop, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_751_102_678_041),
      duration: Keyword.get(opts, :duration, 78_256_000)
    }

    metadata =
      opts
      |> build_event_store_append_to_stream_metadata()
      |> maybe_put(:error, opts)

    event_name = [:commanded, :event_store, :append_to_stream, :stop]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_stream_forward_start, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_916_612_542),
      system_time: Keyword.get(opts, :system_time, 1_769_137_874_780_173_542)
    }

    metadata = build_event_store_stream_forward_metadata(opts)
    event_name = [:commanded, :event_store, :stream_forward, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_stream_forward_stop, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_895_139_292),
      duration: Keyword.get(opts, :duration, 21_473_250)
    }

    metadata =
      opts
      |> build_event_store_stream_forward_metadata()
      |> maybe_put(:error, opts)

    event_name = [:commanded, :event_store, :stream_forward, :stop]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_subscribe_to_start, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_834_979_708),
      system_time: Keyword.get(opts, :system_time, 1_769_132_779_441_574_667)
    }

    metadata = build_event_store_subscribe_to_metadata(opts)
    event_name = [:commanded, :event_store, :subscribe_to, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_subscribe_to_stop, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_766_990_583),
      duration: Keyword.get(opts, :duration, 67_989_125)
    }

    metadata =
      opts
      |> build_event_store_subscribe_to_metadata()
      |> maybe_put(:error, opts)

    event_name = [:commanded, :event_store, :subscribe_to, :stop]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_record_snapshot_start, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_928_468_041),
      system_time: Keyword.get(opts, :system_time, 1_769_132_779_348_086_042)
    }

    metadata = build_event_store_record_snapshot_metadata(opts)
    event_name = [:commanded, :event_store, :record_snapshot, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_record_snapshot_stop, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_904_372_541),
      duration: Keyword.get(opts, :duration, 24_095_500)
    }

    metadata =
      opts
      |> build_event_store_record_snapshot_metadata()
      |> maybe_put(:error, opts)

    event_name = [:commanded, :event_store, :record_snapshot, :stop]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_read_snapshot_start, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_548_527_667),
      system_time: Keyword.get(opts, :system_time, 1_769_137_875_148_258_375)
    }

    metadata = build_event_store_read_snapshot_metadata(opts)
    event_name = [:commanded, :event_store, :read_snapshot, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_read_snapshot_stop, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_534_117_958),
      duration: Keyword.get(opts, :duration, 14_409_709)
    }

    metadata =
      opts
      |> build_event_store_read_snapshot_metadata()
      |> maybe_put(:error, opts)

    event_name = [:commanded, :event_store, :read_snapshot, :stop]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_ack_event_start, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_664_247_583),
      system_time: Keyword.get(opts, :system_time, 1_769_137_875_032_538_583)
    }

    metadata = build_event_store_ack_event_metadata(opts)
    event_name = [:commanded, :event_store, :ack_event, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_ack_event_stop, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_645_331_875),
      duration: Keyword.get(opts, :duration, 18_915_708)
    }

    metadata =
      opts
      |> build_event_store_ack_event_metadata()
      |> maybe_put(:error, opts)

    event_name = [:commanded, :event_store, :ack_event, :stop]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_delete_snapshot_start, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_736_021_125),
      system_time: Keyword.get(opts, :system_time, 1_769_134_205_344_113_250)
    }

    metadata = build_event_store_delete_snapshot_metadata(opts)
    event_name = [:commanded, :event_store, :delete_snapshot, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_delete_snapshot_stop, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_706_717_459),
      duration: Keyword.get(opts, :duration, 29_303_666)
    }

    metadata =
      opts
      |> build_event_store_delete_snapshot_metadata()
      |> maybe_put(:error, opts)

    event_name = [:commanded, :event_store, :delete_snapshot, :stop]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_subscribe_start, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_920_081_042),
      system_time: Keyword.get(opts, :system_time, 1_769_134_231_524_992_167)
    }

    metadata = build_event_store_subscribe_metadata(opts)
    event_name = [:commanded, :event_store, :subscribe, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_subscribe_stop, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_920_064_292),
      duration: Keyword.get(opts, :duration, 16_750)
    }

    metadata =
      opts
      |> build_event_store_subscribe_metadata()
      |> maybe_put(:error, opts)

    event_name = [:commanded, :event_store, :subscribe, :stop]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_unsubscribe_start, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_751_014_001_958),
      system_time: Keyword.get(opts, :system_time, 1_769_134_231_431_071_083)
    }

    metadata = build_event_store_unsubscribe_metadata(opts)
    event_name = [:commanded, :event_store, :unsubscribe, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_unsubscribe_stop, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_750_998_181_375),
      duration: Keyword.get(opts, :duration, 15_820_583)
    }

    metadata =
      opts
      |> build_event_store_unsubscribe_metadata()
      |> maybe_put(:error, opts)

    event_name = [:commanded, :event_store, :unsubscribe, :stop]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_delete_subscription_start, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_751_154_259_667),
      system_time: Keyword.get(opts, :system_time, 1_769_134_231_290_813_417)
    }

    metadata = build_event_store_delete_subscription_metadata(opts)
    event_name = [:commanded, :event_store, :delete_subscription, :start]

    {event_name, measurements, metadata}
  end

  def build_telemetry_event(:event_store_delete_subscription_stop, opts) do
    measurements = %{
      monotonic_time: Keyword.get(opts, :monotonic_time, -576_460_751_123_691_917),
      duration: Keyword.get(opts, :duration, 30_567_750)
    }

    metadata =
      opts
      |> build_event_store_delete_subscription_metadata()
      |> maybe_put(:error, opts)

    event_name = [:commanded, :event_store, :delete_subscription, :stop]

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

  def build_event_store_append_to_stream_metadata(opts \\ []) do
    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      stream_uuid: Keyword.get(opts, :stream_uuid, UUID.uuid4()),
      expected_version: Keyword.get(opts, :expected_version, 0)
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      stream_uuid: Keyword.fetch!(opts, :stream_uuid),
      expected_version: Keyword.fetch!(opts, :expected_version)
    }
  end

  def build_event_store_stream_forward_metadata(opts \\ []) do
    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      stream_uuid: Keyword.get(opts, :stream_uuid, UUID.uuid4()),
      start_version: Keyword.get(opts, :start_version, 0),
      read_batch_size: Keyword.get(opts, :read_batch_size, 1000)
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      stream_uuid: Keyword.fetch!(opts, :stream_uuid),
      start_version: Keyword.fetch!(opts, :start_version),
      read_batch_size: Keyword.fetch!(opts, :read_batch_size)
    }
  end

  def build_event_store_subscribe_to_metadata(opts \\ []) do
    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      stream_uuid: Keyword.get(opts, :stream_uuid, :all),
      subscription_name: Keyword.get(opts, :subscription_name, "test_subscription"),
      subscriber: Keyword.get(opts, :subscriber, self()),
      start_from: Keyword.get(opts, :start_from, :origin)
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      stream_uuid: Keyword.fetch!(opts, :stream_uuid),
      subscription_name: Keyword.fetch!(opts, :subscription_name),
      subscriber: Keyword.fetch!(opts, :subscriber),
      start_from: Keyword.fetch!(opts, :start_from)
    }
  end

  def build_event_store_ack_event_metadata(opts \\ []) do
    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      subscription: Keyword.get(opts, :subscription, self()),
      event: Keyword.get(opts, :event, %{})
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      subscription: Keyword.fetch!(opts, :subscription),
      event: Keyword.fetch!(opts, :event)
    }
  end

  def build_event_store_record_snapshot_metadata(opts \\ []) do
    source_uuid = Keyword.get(opts, :source_uuid, UUID.uuid4())

    snapshot =
      Keyword.get_lazy(opts, :snapshot, fn ->
        %Commanded.EventStore.SnapshotData{
          source_uuid: source_uuid,
          source_version: 5,
          source_type: "TestAggregate",
          data: %{state: "test"},
          metadata: %{},
          created_at: DateTime.utc_now()
        }
      end)

    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      snapshot: snapshot
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      snapshot: Keyword.fetch!(opts, :snapshot)
    }
  end

  def build_event_store_read_snapshot_metadata(opts \\ []) do
    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      source_uuid: Keyword.get(opts, :source_uuid, UUID.uuid4())
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      source_uuid: Keyword.fetch!(opts, :source_uuid)
    }
  end

  def build_event_store_delete_snapshot_metadata(opts \\ []) do
    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      source_uuid: Keyword.get(opts, :source_uuid, UUID.uuid4())
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      source_uuid: Keyword.fetch!(opts, :source_uuid)
    }
  end

  def build_event_store_subscribe_metadata(opts \\ []) do
    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      stream_uuid: Keyword.get(opts, :stream_uuid, UUID.uuid4())
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      stream_uuid: Keyword.fetch!(opts, :stream_uuid)
    }
  end

  def build_event_store_unsubscribe_metadata(opts \\ []) do
    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      subscription: Keyword.get(opts, :subscription, self())
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      subscription: Keyword.fetch!(opts, :subscription)
    }
  end

  def build_event_store_delete_subscription_metadata(opts \\ []) do
    defaults = [
      application: Keyword.get(opts, :application, MockApp),
      subscribe_to: Keyword.get(opts, :subscribe_to, :all),
      handler_name: Keyword.get(opts, :handler_name, "TestHandler")
    ]

    opts = Keyword.merge(defaults, opts)

    %{
      application: Keyword.fetch!(opts, :application),
      subscribe_to: Keyword.fetch!(opts, :subscribe_to),
      handler_name: Keyword.fetch!(opts, :handler_name)
    }
  end
end
