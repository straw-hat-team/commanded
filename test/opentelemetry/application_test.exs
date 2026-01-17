defmodule Commanded.OpenTelemetry.ApplicationTest do
  use Commanded.OpenTelemetryCase, async: false

  alias Commanded.DefaultApp
  alias Commanded.Middleware.Commands.IncrementCount
  alias Commanded.OpenTelemetry.Application, as: OTelApplication
  alias Commanded.TestSupport.Factory
  alias Commanded.UUID

  setup do
    start_supervised!(DefaultApp)

    detach_handlers()
    OTelApplication.setup()

    :ok
  end

  defmodule TestRouter do
    use Commanded.Commands.Router

    alias Commanded.Middleware.Commands.CommandHandler
    alias Commanded.Middleware.Commands.CounterAggregateRoot

    dispatch IncrementCount,
      to: CommandHandler,
      aggregate: CounterAggregateRoot,
      identity: :aggregate_uuid
  end

  describe "setup/0" do
    test "attaches telemetry handlers for application dispatch events" do
      detach_handlers()

      OTelApplication.setup()

      for event <- [
            [:commanded, :application, :dispatch, :start],
            [:commanded, :application, :dispatch, :stop],
            [:commanded, :application, :dispatch, :exception]
          ] do
        handlers = :telemetry.list_handlers(event)

        assert Enum.any?(
                 handlers,
                 &match?(%{id: {OTelApplication, :dispatch}}, &1)
               ),
               "Expected handler for event #{inspect(event)}"
      end
    end

    test "calling setup twice raises MatchError (fail fast)" do
      detach_handlers()

      :ok = OTelApplication.setup()

      handlers = :telemetry.list_handlers([:commanded, :application, :dispatch, :start])
      assert length(handlers) == 1

      assert_raise MatchError, fn ->
        OTelApplication.setup()
      end
    end
  end

  describe "application dispatch" do
    test "creates span on successful dispatch" do
      aggregate_uuid = UUID.uuid4()
      causation_id = UUID.uuid4()
      correlation_id = UUID.uuid4()

      command = %IncrementCount{aggregate_uuid: aggregate_uuid}

      assert :ok =
               TestRouter.dispatch(command,
                 application: DefaultApp,
                 command_uuid: causation_id,
                 correlation_id: correlation_id
               )

      assert_receive {:span,
                      span(
                        name: "dispatch Commanded.Middleware.Commands.CommandHandler",
                        kind: :consumer,
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "dispatch",
               "messaging.destination.name": "Commanded.Middleware.Commands.CommandHandler",
               "messaging.message.id": causation_id,
               "messaging.message.conversation_id": correlation_id,
               "code.function": "handle",
               "code.namespace": "Commanded.Middleware.Commands.CommandHandler",
               "commanded.handler.kind": "command_handler",
               "commanded.application": Commanded.DefaultApp,
               "commanded.command": "Commanded.Middleware.Commands.IncrementCount",
               "commanded.correlation_id": correlation_id,
               "commanded.causation_id": causation_id
             }
    end
  end

  describe "error handling" do
    setup do
      detach_handlers()
      OTelApplication.setup()
      :ok
    end

    test "sets error status when dispatch returns error in stop" do
      causation_id = UUID.uuid4()
      correlation_id = UUID.uuid4()

      meta =
        Factory.build_application_dispatch_metadata(
          causation_id: causation_id,
          correlation_id: correlation_id
        )

      :telemetry.execute([:commanded, :application, :dispatch, :start], %{}, meta)

      stop_meta = Map.put(meta, :error, :validation_failed)

      :telemetry.execute(
        [:commanded, :application, :dispatch, :stop],
        %{duration: 1000},
        stop_meta
      )

      assert_receive {:span,
                      span(
                        name: "dispatch Commanded.TestSupport.TestDomain.Account",
                        status: {:status, :error, error_message},
                        attributes: span_attrs
                      )},
                     1000

      assert error_message == ":validation_failed"

      assert :otel_attributes.map(span_attrs) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "dispatch",
               "messaging.destination.name": "Commanded.TestSupport.TestDomain.Account",
               "messaging.message.id": causation_id,
               "messaging.message.conversation_id": correlation_id,
               "code.function": "execute",
               "code.namespace": "Commanded.TestSupport.TestDomain.Account",
               "commanded.handler.kind": "command_handler",
               "commanded.application": MockApp,
               "commanded.command": "Commanded.TestSupport.TestDomain.OpenAccount",
               "commanded.correlation_id": correlation_id,
               "commanded.causation_id": causation_id,
               "error.type": "validation_failed"
             }
    end

    test "handles ArgumentError exception" do
      {_event_name, _measurements, meta} =
        Factory.build_telemetry_event(:application_dispatch_exception,
          reason: %ArgumentError{message: "invalid command argument"}
        )

      context = meta.execution_context

      :telemetry.execute([:commanded, :application, :dispatch, :start], %{}, meta)

      :telemetry.execute(
        [:commanded, :application, :dispatch, :exception],
        %{duration: 100},
        meta
      )

      assert_receive {:span,
                      span(
                        name: "dispatch Commanded.TestSupport.TestDomain.Account",
                        status: {:status, :error, error_msg},
                        attributes: span_attrs
                      )},
                     1000

      assert error_msg == "** (ArgumentError) invalid command argument"

      assert :otel_attributes.map(span_attrs) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "dispatch",
               "messaging.destination.name": "Commanded.TestSupport.TestDomain.Account",
               "messaging.message.id": context.causation_id,
               "messaging.message.conversation_id": context.correlation_id,
               "code.function": to_string(context.function),
               "code.namespace": "Commanded.TestSupport.TestDomain.Account",
               "commanded.handler.kind": "command_handler",
               "commanded.application": meta.application,
               "commanded.command": "Commanded.TestSupport.TestDomain.OpenAccount",
               "commanded.correlation_id": context.correlation_id,
               "commanded.causation_id": context.causation_id,
               "erlang.exception.kind": :error,
               "error.type": "Elixir.ArgumentError"
             }
    end

    test "handles RuntimeError exception" do
      {_event_name, _measurements, meta} =
        Factory.build_telemetry_event(:application_dispatch_exception,
          reason: %RuntimeError{message: "dispatch execution failed"}
        )

      context = meta.execution_context

      :telemetry.execute([:commanded, :application, :dispatch, :start], %{}, meta)

      :telemetry.execute(
        [:commanded, :application, :dispatch, :exception],
        %{duration: 100},
        meta
      )

      assert_receive {:span,
                      span(
                        name: "dispatch Commanded.TestSupport.TestDomain.Account",
                        status: {:status, :error, error_msg},
                        attributes: span_attrs
                      )},
                     1000

      assert error_msg == "** (RuntimeError) dispatch execution failed"

      assert :otel_attributes.map(span_attrs) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "dispatch",
               "messaging.destination.name": "Commanded.TestSupport.TestDomain.Account",
               "messaging.message.id": context.causation_id,
               "messaging.message.conversation_id": context.correlation_id,
               "code.function": to_string(context.function),
               "code.namespace": "Commanded.TestSupport.TestDomain.Account",
               "commanded.handler.kind": "command_handler",
               "commanded.application": meta.application,
               "commanded.command": "Commanded.TestSupport.TestDomain.OpenAccount",
               "commanded.correlation_id": context.correlation_id,
               "commanded.causation_id": context.causation_id,
               "erlang.exception.kind": :error,
               "error.type": "Elixir.RuntimeError"
             }
    end

    test "records exception event with proper attributes" do
      {_event_name, _measurements, meta} =
        Factory.build_telemetry_event(:application_dispatch_exception,
          reason: %RuntimeError{message: "failed"}
        )

      :telemetry.execute([:commanded, :application, :dispatch, :start], %{}, meta)

      :telemetry.execute(
        [:commanded, :application, :dispatch, :exception],
        %{duration: 100},
        meta
      )

      assert_receive {:span,
                      span(
                        name: "dispatch Commanded.TestSupport.TestDomain.Account",
                        events: events
                      )},
                     1000

      events_list = :otel_events.list(events)
      exception_event = Enum.find(events_list, fn event -> elem(event, 2) == :exception end)
      {:event, _timestamp, :exception, attrs_tuple} = exception_event
      {:attributes, _, _, _, attrs_map} = attrs_tuple

      assert attrs_map[:"exception.type"] == "Elixir.RuntimeError"
      assert attrs_map[:"exception.message"] == "failed"
    end
  end

  defp detach_handlers do
    for event <- [
          [:commanded, :application, :dispatch, :start],
          [:commanded, :application, :dispatch, :stop],
          [:commanded, :application, :dispatch, :exception]
        ] do
      for handler <- :telemetry.list_handlers(event) do
        :telemetry.detach(handler.id)
      end
    end
  end
end
