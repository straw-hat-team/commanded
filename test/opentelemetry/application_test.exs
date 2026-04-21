defmodule Commanded.OpenTelemetry.ApplicationTest do
  use Commanded.OpenTelemetryCase, async: false

  alias Commanded.DefaultApp
  alias Commanded.Middleware.Commands.IncrementCount
  alias Commanded.OpenTelemetry.Application, as: OTelApplication
  alias Commanded.TestSupport.Factory
  alias Commanded.UUID

  require OpenTelemetry.Tracer, as: Tracer

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
               "commanded.application": "Commanded.DefaultApp",
               "commanded.command": "Commanded.Middleware.Commands.IncrementCount",
               "commanded.correlation_id": correlation_id,
               "commanded.causation_id": causation_id
             }
    end
  end

  describe "context propagation — dispatch within an active span" do
    @describetag :context_propagation

    test "dispatch span becomes a child of the active parent span (same trace_id, correct parent_span_id)" do
      causation_id = UUID.uuid4()
      correlation_id = UUID.uuid4()

      # Simulate a gRPC/HTTP handler that creates a parent span, then dispatches a command.
      # The dispatch span MUST be a child of this parent span.
      {parent_trace_id, parent_span_id} =
        Tracer.with_span "grpc.server.request" do
          ctx = Tracer.current_span_ctx()
          parent_trace_id = :otel_span.trace_id(ctx)
          parent_span_id = :otel_span.span_id(ctx)

          meta =
            Factory.build_application_dispatch_metadata(
              causation_id: causation_id,
              correlation_id: correlation_id
            )

          :telemetry.execute([:commanded, :application, :dispatch, :start], %{}, meta)

          :telemetry.execute(
            [:commanded, :application, :dispatch, :stop],
            %{duration: 1000},
            meta
          )

          {parent_trace_id, parent_span_id}
        end

      assert_receive {:span,
                      span(
                        name: "dispatch Commanded.TestSupport.TestDomain.Account",
                        trace_id: dispatch_trace_id,
                        parent_span_id: dispatch_parent_span_id
                      )},
                     1000

      assert dispatch_trace_id == parent_trace_id,
             "Dispatch span should share the same trace_id as the parent span. " <>
               "Expected: #{parent_trace_id}, got: #{dispatch_trace_id}. " <>
               "This means the dispatch span started a new trace instead of joining the parent."

      assert dispatch_parent_span_id == parent_span_id,
             "Dispatch span's parent_span_id should be the gRPC server span. " <>
               "Expected: #{parent_span_id}, got: #{inspect(dispatch_parent_span_id)}. " <>
               "This means context propagation is broken — the dispatch span is disconnected."
    end

    test "dispatch span without active parent and no metadata starts a new trace" do
      causation_id = UUID.uuid4()
      correlation_id = UUID.uuid4()

      meta =
        Factory.build_application_dispatch_metadata(
          causation_id: causation_id,
          correlation_id: correlation_id
        )

      :telemetry.execute([:commanded, :application, :dispatch, :start], %{}, meta)
      :telemetry.execute([:commanded, :application, :dispatch, :stop], %{duration: 1000}, meta)

      assert_receive {:span,
                      span(
                        name: "dispatch Commanded.TestSupport.TestDomain.Account",
                        parent_span_id: :undefined
                      )},
                     1000
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
               "commanded.application": "MockApp",
               "commanded.command": "Commanded.TestSupport.TestDomain.OpenAccount",
               "commanded.correlation_id": correlation_id,
               "commanded.causation_id": causation_id,
               "error.type": ":validation_failed"
             }
    end

    test "allows returned error status to stay unset" do
      detach_handlers()
      test_pid = self()

      OTelApplication.setup(
        error_status: fn event_name, measurements, meta, config ->
          send(test_pid, {:error_status_callback, event_name, measurements, meta, config})
          :unset
        end
      )

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
                        status: status,
                        attributes: span_attrs
                      )},
                     1000

      assert_receive {:error_status_callback, callback_event_name, callback_measurements,
                      callback_meta, callback_config},
                     1000

      assert callback_event_name == [:commanded, :application, :dispatch, :stop]
      assert callback_measurements.duration == 1000
      assert callback_meta.error == :validation_failed
      assert is_function(Keyword.fetch!(callback_config, :error_status), 4)
      assert status == {:status, :unset, ""}
      assert :otel_attributes.map(span_attrs)[:"error.type"] == ":validation_failed"
    end

    test "uses the formatted error message when callback returns error" do
      detach_handlers()

      OTelApplication.setup(
        error_status: fn _event_name, _measurements, _meta, _config -> :error end
      )

      meta = Factory.build_application_dispatch_metadata()

      :telemetry.execute([:commanded, :application, :dispatch, :start], %{}, meta)

      :telemetry.execute(
        [:commanded, :application, :dispatch, :stop],
        %{duration: 1000},
        Map.put(meta, :error, :validation_failed)
      )

      assert_receive {:span, span(status: {:status, :error, error_message})},
                     1000

      assert error_message == ":validation_failed"
    end

    test "keeps exception status handling unchanged when error_status is configured" do
      detach_handlers()

      OTelApplication.setup(
        error_status: fn _event_name, _measurements, _meta, _config -> :unset end
      )

      {_event_name, _measurements, meta} =
        Factory.build_telemetry_event(:application_dispatch_exception,
          reason: %ArgumentError{message: "invalid command argument"}
        )

      :telemetry.execute([:commanded, :application, :dispatch, :start], %{}, meta)

      :telemetry.execute(
        [:commanded, :application, :dispatch, :exception],
        %{duration: 100},
        meta
      )

      assert_receive {:span, span(status: {:status, :error, error_msg})},
                     1000

      assert error_msg == "** (ArgumentError) invalid command argument"
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
               "commanded.application": inspect(meta.application),
               "commanded.command": "Commanded.TestSupport.TestDomain.OpenAccount",
               "commanded.correlation_id": context.correlation_id,
               "commanded.causation_id": context.causation_id,
               "erlang.exception.kind": :error,
               "error.type": "ArgumentError"
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
               "commanded.application": inspect(meta.application),
               "commanded.command": "Commanded.TestSupport.TestDomain.OpenAccount",
               "commanded.correlation_id": context.correlation_id,
               "commanded.causation_id": context.causation_id,
               "erlang.exception.kind": :error,
               "error.type": "RuntimeError"
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
