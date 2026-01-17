defmodule Commanded.OpenTelemetry.EventHandlerTest do
  use Commanded.OpenTelemetryCase, async: false

  alias Commanded.OpenTelemetry.EventHandler
  alias Commanded.TestSupport.Factory

  require OpenTelemetry.Tracer, as: Tracer

  describe "setup/1" do
    test "attaches telemetry handlers for single and batch events" do
      detach_handlers()

      EventHandler.setup()

      for event <- [
            [:commanded, :event, :handle, :start],
            [:commanded, :event, :handle, :stop],
            [:commanded, :event, :handle, :exception]
          ] do
        handlers = :telemetry.list_handlers(event)

        assert Enum.any?(
                 handlers,
                 &match?(%{id: {EventHandler, :handle}}, &1)
               ),
               "Expected handler for event #{inspect(event)}"
      end

      for event <- [
            [:commanded, :event, :batch, :start],
            [:commanded, :event, :batch, :stop],
            [:commanded, :event, :batch, :exception]
          ] do
        handlers = :telemetry.list_handlers(event)

        assert Enum.any?(
                 handlers,
                 &match?(%{id: {EventHandler, :batch}}, &1)
               ),
               "Expected handler for event #{inspect(event)}"
      end
    end

    test "stores span_relationship config in handler" do
      detach_handlers()

      EventHandler.setup(span_relationship: :child)

      [handler] =
        :telemetry.list_handlers([:commanded, :event, :handle, :start])
        |> Enum.filter(&match?(%{id: {EventHandler, :handle}}, &1))

      assert handler.config.span_relationship == :child
    end

    test "calling setup twice raises MatchError (fail fast)" do
      detach_handlers()

      :ok = EventHandler.setup()

      handlers = :telemetry.list_handlers([:commanded, :event, :handle, :start])
      assert length(handlers) == 1

      assert_raise MatchError, fn ->
        EventHandler.setup()
      end
    end
  end

  describe "single event handling - attribute completeness" do
    setup do
      detach_handlers()
      EventHandler.setup()
      :ok
    end

    test "includes ALL required span attributes" do
      meta =
        Factory.build_event_handler_metadata(:account_projector,
          event_number: 42,
          stream_version: 7
        )

      recorded_event = meta.recorded_event

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        kind: :consumer,
                        status: status,
                        attributes: attributes
                      )},
                     1000

      assert status == :undefined

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "handle",
               "messaging.destination.name": "MyApp.Projectors.AccountProjector",
               "messaging.destination.subscription.name": "MyApp.Projectors.AccountProjector",
               "messaging.message.id": recorded_event.event_id,
               "messaging.message.conversation_id": recorded_event.correlation_id,
               "messaging.consumer.group.name": MyApp.CommandedApp,
               "code.function": "handle",
               "code.namespace": "MyApp.Projectors.AccountProjector",
               "commanded.application": MyApp.CommandedApp,
               "commanded.event": "Elixir.MyApp.Events.AccountOpened",
               "commanded.event.number": 42,
               "commanded.correlation_id": recorded_event.correlation_id,
               "commanded.causation_id": recorded_event.causation_id,
               "commanded.handler.name": "MyApp.Projectors.AccountProjector",
               "commanded.stream.id": recorded_event.stream_id,
               "commanded.stream.version": 7,
               "commanded.handler.kind": "event_handler"
             }
    end
  end

  describe "batch event handling - attribute completeness" do
    setup do
      detach_handlers()
      EventHandler.setup()
      :ok
    end

    test "includes ALL required batch span attributes" do
      first_event_id = Commanded.UUID.uuid4()
      last_event_id = Commanded.UUID.uuid4()

      meta =
        Factory.build_batch_handler_metadata(:transaction_projector,
          first_event_id: first_event_id,
          last_event_id: last_event_id,
          event_count: 100
        )

      :telemetry.span([:commanded, :event, :batch], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "batch MyApp.Projectors.TransactionProjector",
                        kind: :consumer,
                        attributes: attributes
                      )},
                     1000

      attrs = :otel_attributes.map(attributes)

      assert attrs == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "batch",
               "messaging.destination.name": "MyApp.Projectors.TransactionProjector",
               "messaging.destination.subscription.name": "MyApp.Projectors.TransactionProjector",
               "messaging.consumer.group.name": MyApp.CommandedApp,
               "messaging.batch.message_count": 100,
               "code.function": "handle_batch",
               "code.namespace": "MyApp.Projectors.TransactionProjector",
               "commanded.application": MyApp.CommandedApp,
               "commanded.handler.name": "MyApp.Projectors.TransactionProjector",
               "commanded.event.count": 100,
               "commanded.handler.kind": "event_handler",
               "commanded.batch.first_event_id": first_event_id,
               "commanded.batch.last_event_id": last_event_id
             }
    end
  end

  describe "error handling - single events" do
    setup do
      detach_handlers()
      EventHandler.setup()
      :ok
    end

    test "sets error status with error message when handler returns error" do
      meta = Factory.build_event_handler_metadata(:account_projector)
      recorded_event = meta.recorded_event

      :telemetry.execute([:commanded, :event, :handle, :start], %{}, meta)

      # Commanded emits only the reason atom, not {:error, reason} tuple
      stop_meta = Map.put(meta, :error, :unique_constraint_violation)
      :telemetry.execute([:commanded, :event, :handle, :stop], %{duration: 1000}, stop_meta)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        status: {:status, :error, error_message},
                        attributes: span_attrs
                      )},
                     1000

      # Atom errors are formatted via inspect()
      assert error_message == ":unique_constraint_violation"

      assert :otel_attributes.map(span_attrs) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "handle",
               "messaging.destination.name": "MyApp.Projectors.AccountProjector",
               "messaging.destination.subscription.name": "MyApp.Projectors.AccountProjector",
               "messaging.message.id": recorded_event.event_id,
               "messaging.message.conversation_id": recorded_event.correlation_id,
               "messaging.consumer.group.name": MyApp.CommandedApp,
               "code.function": "handle",
               "code.namespace": "MyApp.Projectors.AccountProjector",
               "commanded.application": MyApp.CommandedApp,
               "commanded.event": "Elixir.MyApp.Events.AccountOpened",
               "commanded.event.number": recorded_event.event_number,
               "commanded.correlation_id": recorded_event.correlation_id,
               "commanded.causation_id": recorded_event.causation_id,
               "commanded.handler.name": "MyApp.Projectors.AccountProjector",
               "commanded.stream.id": recorded_event.stream_id,
               "commanded.stream.version": recorded_event.stream_version,
               "commanded.handler.kind": "event_handler",
               "error.type": "unique_constraint_violation"
             }
    end

    test "records exception event with type, message, and stacktrace" do
      meta =
        Factory.build_exception_metadata(:account_projector)

      recorded_event = meta.recorded_event

      :telemetry.execute([:commanded, :event, :handle, :start], %{}, meta)
      :telemetry.execute([:commanded, :event, :handle, :exception], %{duration: 500}, meta)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        status: {:status, :error, _},
                        attributes: span_attrs,
                        events: events
                      )},
                     1000

      assert :otel_attributes.map(span_attrs) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "handle",
               "messaging.destination.name": "MyApp.Projectors.AccountProjector",
               "messaging.destination.subscription.name": "MyApp.Projectors.AccountProjector",
               "messaging.message.id": recorded_event.event_id,
               "messaging.message.conversation_id": recorded_event.correlation_id,
               "messaging.consumer.group.name": MyApp.CommandedApp,
               "code.function": "handle",
               "code.namespace": "MyApp.Projectors.AccountProjector",
               "commanded.application": MyApp.CommandedApp,
               "commanded.event": "Elixir.MyApp.Events.AccountOpened",
               "commanded.event.number": recorded_event.event_number,
               "commanded.correlation_id": recorded_event.correlation_id,
               "commanded.causation_id": recorded_event.causation_id,
               "commanded.handler.name": "MyApp.Projectors.AccountProjector",
               "commanded.stream.id": recorded_event.stream_id,
               "commanded.stream.version": recorded_event.stream_version,
               "commanded.handler.kind": "event_handler",
               "erlang.exception.kind": :error,
               "error.type": "Elixir.KeyError"
             }

      events_list = :otel_events.list(events)
      [exception_event] = Enum.filter(events_list, fn event(name: n) -> n == :exception end)

      event(attributes: exc_attrs) = exception_event

      exc_attrs_map = :otel_attributes.map(exc_attrs)

      assert map_size(exc_attrs_map) == 3
      assert exc_attrs_map[:"exception.type"] == "Elixir.KeyError"

      assert exc_attrs_map[:"exception.message"] ==
               "key :account_number not found in:\n\n    %{balance: 100}\n"

      # Version number in stacktrace changes per release
      stacktrace = exc_attrs_map[:"exception.stacktrace"]
      {:ok, commanded_version} = :application.get_key(:commanded, :vsn)

      expected_stacktrace =
        "    lib/my_app/projectors/account_projector.ex:45: MyApp.Projectors.AccountProjector.handle/2\n" <>
          "    (commanded #{commanded_version}) lib/commanded/event/handler.ex:1192: Commanded.Event.Handler.delegate_event_to_handler/2\n"

      assert stacktrace == expected_stacktrace
    end

    test "handles ArgumentError exception" do
      # Commanded's rescue blocks always emit kind: :error
      meta =
        Factory.build_exception_metadata(:account_projector,
          reason: %ArgumentError{message: "invalid argument"}
        )

      recorded_event = meta.recorded_event

      :telemetry.execute([:commanded, :event, :handle, :start], %{}, meta)
      :telemetry.execute([:commanded, :event, :handle, :exception], %{duration: 100}, meta)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        status: {:status, :error, error_msg},
                        attributes: span_attrs
                      )},
                     1000

      # Exception telemetry uses Exception.format_banner()
      assert error_msg == "** (ArgumentError) invalid argument"

      assert :otel_attributes.map(span_attrs) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "handle",
               "messaging.destination.name": "MyApp.Projectors.AccountProjector",
               "messaging.destination.subscription.name": "MyApp.Projectors.AccountProjector",
               "messaging.message.id": recorded_event.event_id,
               "messaging.message.conversation_id": recorded_event.correlation_id,
               "messaging.consumer.group.name": MyApp.CommandedApp,
               "code.function": "handle",
               "code.namespace": "MyApp.Projectors.AccountProjector",
               "commanded.application": MyApp.CommandedApp,
               "commanded.event": recorded_event.event_type,
               "commanded.event.number": recorded_event.event_number,
               "commanded.correlation_id": recorded_event.correlation_id,
               "commanded.causation_id": recorded_event.causation_id,
               "commanded.handler.name": "MyApp.Projectors.AccountProjector",
               "commanded.stream.id": recorded_event.stream_id,
               "commanded.stream.version": recorded_event.stream_version,
               "commanded.handler.kind": "event_handler",
               "erlang.exception.kind": :error,
               "error.type": "Elixir.ArgumentError"
             }
    end

    test "handles RuntimeError exception" do
      # Commanded's rescue blocks always emit kind: :error
      meta =
        Factory.build_exception_metadata(:account_projector,
          reason: %RuntimeError{message: "something went wrong"}
        )

      recorded_event = meta.recorded_event

      :telemetry.execute([:commanded, :event, :handle, :start], %{}, meta)
      :telemetry.execute([:commanded, :event, :handle, :exception], %{duration: 100}, meta)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        status: {:status, :error, error_msg},
                        attributes: span_attrs
                      )},
                     1000

      # Exception telemetry uses Exception.format_banner()
      assert error_msg == "** (RuntimeError) something went wrong"

      assert :otel_attributes.map(span_attrs) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "handle",
               "messaging.destination.name": "MyApp.Projectors.AccountProjector",
               "messaging.destination.subscription.name": "MyApp.Projectors.AccountProjector",
               "messaging.message.id": recorded_event.event_id,
               "messaging.message.conversation_id": recorded_event.correlation_id,
               "messaging.consumer.group.name": MyApp.CommandedApp,
               "code.function": "handle",
               "code.namespace": "MyApp.Projectors.AccountProjector",
               "commanded.application": MyApp.CommandedApp,
               "commanded.event": recorded_event.event_type,
               "commanded.event.number": recorded_event.event_number,
               "commanded.correlation_id": recorded_event.correlation_id,
               "commanded.causation_id": recorded_event.causation_id,
               "commanded.handler.name": "MyApp.Projectors.AccountProjector",
               "commanded.stream.id": recorded_event.stream_id,
               "commanded.stream.version": recorded_event.stream_version,
               "commanded.handler.kind": "event_handler",
               "erlang.exception.kind": :error,
               "error.type": "Elixir.RuntimeError"
             }
    end
  end

  describe "error handling - batch events" do
    setup do
      detach_handlers()
      EventHandler.setup()
      :ok
    end

    test "sets error status when batch handler returns error" do
      first_event_id = Commanded.UUID.uuid4()
      last_event_id = Commanded.UUID.uuid4()

      meta =
        Factory.build_batch_handler_metadata(:transaction_projector,
          first_event_id: first_event_id,
          last_event_id: last_event_id
        )

      :telemetry.execute([:commanded, :event, :batch, :start], %{}, meta)

      stop_meta = Map.put(meta, :error, :transaction_rollback)
      :telemetry.execute([:commanded, :event, :batch, :stop], %{duration: 2000}, stop_meta)

      assert_receive {:span,
                      span(
                        name: "batch MyApp.Projectors.TransactionProjector",
                        status: {:status, :error, error_message},
                        attributes: span_attrs
                      )},
                     1000

      # Atom errors are formatted via inspect()
      assert error_message == ":transaction_rollback"

      assert :otel_attributes.map(span_attrs) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "batch",
               "messaging.destination.name": "MyApp.Projectors.TransactionProjector",
               "messaging.destination.subscription.name": "MyApp.Projectors.TransactionProjector",
               "messaging.consumer.group.name": MyApp.CommandedApp,
               "messaging.batch.message_count": 10,
               "code.function": "handle_batch",
               "code.namespace": "MyApp.Projectors.TransactionProjector",
               "commanded.application": MyApp.CommandedApp,
               "commanded.handler.name": "MyApp.Projectors.TransactionProjector",
               "commanded.event.count": 10,
               "commanded.handler.kind": "event_handler",
               "commanded.batch.first_event_id": first_event_id,
               "commanded.batch.last_event_id": last_event_id,
               "error.type": "transaction_rollback"
             }
    end

    test "records exception in batch handler" do
      first_event_id = Commanded.UUID.uuid4()
      last_event_id = Commanded.UUID.uuid4()

      meta =
        Factory.build_batch_handler_metadata(:transaction_projector,
          first_event_id: first_event_id,
          last_event_id: last_event_id,
          reason: %DBConnection.ConnectionError{message: "connection refused"}
        )

      :telemetry.execute([:commanded, :event, :batch, :start], %{}, meta)
      :telemetry.execute([:commanded, :event, :batch, :exception], %{duration: 100}, meta)

      assert_receive {:span,
                      span(
                        name: "batch MyApp.Projectors.TransactionProjector",
                        status: {:status, :error, _},
                        attributes: span_attrs,
                        events: events
                      )},
                     1000

      assert :otel_attributes.map(span_attrs) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "batch",
               "messaging.destination.name": "MyApp.Projectors.TransactionProjector",
               "messaging.destination.subscription.name": "MyApp.Projectors.TransactionProjector",
               "messaging.consumer.group.name": MyApp.CommandedApp,
               "messaging.batch.message_count": 10,
               "code.function": "handle_batch",
               "code.namespace": "MyApp.Projectors.TransactionProjector",
               "commanded.application": MyApp.CommandedApp,
               "commanded.handler.name": "MyApp.Projectors.TransactionProjector",
               "commanded.event.count": 10,
               "commanded.handler.kind": "event_handler",
               "commanded.batch.first_event_id": first_event_id,
               "commanded.batch.last_event_id": last_event_id,
               "erlang.exception.kind": :error,
               "error.type": "Elixir.DBConnection.ConnectionError"
             }

      events_list = :otel_events.list(events)
      assert Enum.any?(events_list, fn event(name: n) -> n == :exception end)
    end
  end

  describe "span_relationship: :child" do
    setup do
      detach_handlers()
      EventHandler.setup(span_relationship: :child)
      :ok
    end

    test "creates child span with correct parent trace_id and span_id" do
      {parent_trace_id, parent_span_id, traceparent} =
        Tracer.with_span "parent.command.dispatch" do
          ctx = Tracer.current_span_ctx()

          {
            :otel_span.trace_id(ctx),
            :otel_span.span_id(ctx),
            encode_traceparent(ctx)
          }
        end

      recorded_event = build_recorded_event("child-test", %{"traceparent" => traceparent})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        trace_id: child_trace_id,
                        parent_span_id: received_parent_span_id
                      )},
                     1000

      assert child_trace_id == parent_trace_id
      assert received_parent_span_id == parent_span_id
    end

    test "creates independent span when no traceparent in metadata" do
      recorded_event = build_recorded_event("orphan-test", %{})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        parent_span_id: :undefined
                      )},
                     1000
    end

    test "creates independent span when traceparent is invalid" do
      recorded_event =
        build_recorded_event("invalid-traceparent", %{"traceparent" => "invalid-format"})

      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        parent_span_id: :undefined
                      )},
                     1000
    end

    test "handles traceparent with tracestate without error" do
      traceparent =
        Tracer.with_span "parent.span" do
          encode_traceparent(Tracer.current_span_ctx())
        end

      recorded_event =
        build_recorded_event("tracestate-test", %{
          "traceparent" => traceparent,
          "tracestate" => "vendor=value123,other=abc"
        })

      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        parent_span_id: parent_id
                      )},
                     1000

      refute parent_id == :undefined
    end
  end

  describe "span_relationship: :link" do
    setup do
      detach_handlers()
      EventHandler.setup(span_relationship: :link)
      :ok
    end

    test "clears stale context - doesn't inherit parent from pre-existing OTel context" do
      # Simulate stale context left by other instrumentation in the same process
      stale_traceparent =
        Tracer.with_span "stale.context.span" do
          encode_traceparent(Tracer.current_span_ctx())
        end

      stale_headers = [{"traceparent", stale_traceparent}]
      stale_ctx = :otel_propagator_text_map.extract_to(:otel_ctx.new(), stale_headers)
      :otel_ctx.attach(stale_ctx)

      recorded_event = build_recorded_event("stale-context-test", %{})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        parent_span_id: parent_id
                      )},
                     1000

      # :link mode must clear stale context, not inherit it
      assert parent_id == :undefined,
             "Expected no parent (fresh trace), but got parent_span_id: #{inspect(parent_id)}. " <>
               "The :link mode is incorrectly inheriting stale context from the process dictionary."
    end

    test "creates span with link containing correct trace_id and span_id" do
      {linked_trace_id, linked_span_id, traceparent} =
        Tracer.with_span "command.dispatch" do
          ctx = Tracer.current_span_ctx()

          {
            :otel_span.trace_id(ctx),
            :otel_span.span_id(ctx),
            encode_traceparent(ctx)
          }
        end

      recorded_event = build_recorded_event("link-test", %{"traceparent" => traceparent})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        trace_id: span_trace_id,
                        parent_span_id: :undefined,
                        links: links
                      )},
                     1000

      # :link mode creates new trace but links to original
      refute span_trace_id == linked_trace_id

      [link(trace_id: link_trace_id, span_id: link_span_id)] = :otel_links.list(links)

      assert link_trace_id == linked_trace_id
      assert link_span_id == linked_span_id
    end

    test "creates span without links when no traceparent in metadata" do
      recorded_event = build_recorded_event("no-link-test", %{})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        parent_span_id: :undefined,
                        links: links
                      )},
                     1000

      assert :otel_links.list(links) == []
    end

    test "creates span without links when traceparent is invalid" do
      recorded_event = build_recorded_event("invalid-link", %{"traceparent" => "not-valid"})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        links: links
                      )},
                     1000

      assert :otel_links.list(links) == []
    end

    test "batch spans have no links (metadata doesn't include individual events)" do
      meta = build_batch_meta()

      :telemetry.span([:commanded, :event, :batch], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "batch MyApp.Projectors.TransactionProjector",
                        parent_span_id: :undefined,
                        links: links
                      )},
                     1000

      assert :otel_links.list(links) == []
    end

    test "batch spans clear stale context - don't inherit parent from pre-existing OTel context" do
      stale_traceparent =
        Tracer.with_span "stale.batch.context.span" do
          encode_traceparent(Tracer.current_span_ctx())
        end

      stale_headers = [{"traceparent", stale_traceparent}]
      stale_ctx = :otel_propagator_text_map.extract_to(:otel_ctx.new(), stale_headers)
      :otel_ctx.attach(stale_ctx)

      meta = build_batch_meta()

      :telemetry.span([:commanded, :event, :batch], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "batch MyApp.Projectors.TransactionProjector",
                        parent_span_id: parent_id
                      )},
                     1000

      assert parent_id == :undefined,
             "Expected no parent (fresh trace), but got parent_span_id: #{inspect(parent_id)}. " <>
               "Batch events with :link mode should clear stale context."
    end
  end

  describe "span_relationship: :none" do
    setup do
      detach_handlers()
      EventHandler.setup(span_relationship: :none)
      :ok
    end

    test "clears stale context - starts fresh trace regardless of pre-existing OTel context" do
      stale_traceparent =
        Tracer.with_span "stale.context.span" do
          encode_traceparent(Tracer.current_span_ctx())
        end

      stale_headers = [{"traceparent", stale_traceparent}]
      stale_ctx = :otel_propagator_text_map.extract_to(:otel_ctx.new(), stale_headers)
      :otel_ctx.attach(stale_ctx)

      recorded_event = build_recorded_event("none-stale-test", %{})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        parent_span_id: parent_id,
                        links: links
                      )},
                     1000

      assert parent_id == :undefined,
             "Expected no parent (fresh trace), but got parent_span_id: #{inspect(parent_id)}. " <>
               "The :none mode should always start fresh traces."

      assert :otel_links.list(links) == []
    end

    test "ignores traceparent completely - no parent, no links" do
      {original_trace_id, traceparent} =
        Tracer.with_span "ignored.span" do
          ctx = Tracer.current_span_ctx()
          {:otel_span.trace_id(ctx), encode_traceparent(ctx)}
        end

      recorded_event = build_recorded_event("none-test", %{"traceparent" => traceparent})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        trace_id: span_trace_id,
                        parent_span_id: :undefined,
                        links: links
                      )},
                     1000

      refute span_trace_id == original_trace_id
      assert :otel_links.list(links) == []
    end

    test "handles missing traceparent gracefully" do
      recorded_event = build_recorded_event("none-no-trace", %{})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        parent_span_id: :undefined,
                        links: links
                      )},
                     1000

      assert :otel_links.list(links) == []
    end

    test "batch spans clear stale context - starts completely fresh trace" do
      stale_traceparent =
        Tracer.with_span "stale.batch.none.span" do
          encode_traceparent(Tracer.current_span_ctx())
        end

      stale_headers = [{"traceparent", stale_traceparent}]
      stale_ctx = :otel_propagator_text_map.extract_to(:otel_ctx.new(), stale_headers)
      :otel_ctx.attach(stale_ctx)

      meta = build_batch_meta()

      :telemetry.span([:commanded, :event, :batch], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "batch MyApp.Projectors.TransactionProjector",
                        parent_span_id: parent_id,
                        links: links
                      )},
                     1000

      assert parent_id == :undefined,
             "Expected no parent (fresh trace), but got parent_span_id: #{inspect(parent_id)}. " <>
               "Batch events with :none mode should always start fresh traces."

      assert :otel_links.list(links) == []
    end
  end

  describe "edge cases" do
    setup do
      detach_handlers()
      EventHandler.setup()
      :ok
    end

    test "handles nil handler_module gracefully" do
      event_id = Commanded.UUID.uuid4()
      aggregate_uuid = Commanded.UUID.uuid4()
      causation_id = Commanded.UUID.uuid4()
      correlation_id = Commanded.UUID.uuid4()

      recorded_event =
        Factory.build_recorded_event(
          event_id: event_id,
          event_number: 1,
          stream_id: "BankAccount-#{aggregate_uuid}",
          stream_version: 1,
          causation_id: causation_id,
          correlation_id: correlation_id,
          event_type: "Elixir.MyApp.Events.AccountOpened",
          data: %{account_number: "ACC-nil-module", initial_balance: 1000},
          metadata: %{}
        )

      meta =
        Factory.build_event_handler_metadata(
          application: TestApp,
          handler_name: "TestHandler",
          handler_module: nil,
          recorded_event: recorded_event
        )

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle ",
                        attributes: attributes
                      )},
                     1000

      assert :otel_attributes.map(attributes) == %{
               "messaging.system": "commanded",
               "messaging.operation.type": :receive,
               "messaging.operation.name": "handle",
               "messaging.destination.name": nil,
               "messaging.destination.subscription.name": "TestHandler",
               "messaging.message.id": event_id,
               "messaging.message.conversation_id": correlation_id,
               "messaging.consumer.group.name": TestApp,
               "code.function": "handle",
               "code.namespace": nil,
               "commanded.application": TestApp,
               "commanded.event": "Elixir.MyApp.Events.AccountOpened",
               "commanded.event.number": 1,
               "commanded.correlation_id": correlation_id,
               "commanded.causation_id": causation_id,
               "commanded.handler.name": "TestHandler",
               "commanded.stream.id": "BankAccount-#{aggregate_uuid}",
               "commanded.stream.version": 1,
               "commanded.handler.kind": "event_handler"
             }
    end

    test "handles empty metadata map in recorded_event" do
      recorded_event = build_recorded_event("empty-meta", %{})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span, span(name: "handle MyApp.Projectors.AccountProjector")}, 1000
    end

    test "handles metadata with only tracestate (no traceparent)" do
      recorded_event = build_recorded_event("only-tracestate", %{"tracestate" => "vendor=value"})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        parent_span_id: :undefined
                      )},
                     1000
    end
  end

  defp build_recorded_event(suffix, metadata) do
    Factory.build_recorded_event(:account_projector,
      data: %{account_number: "ACC-#{suffix}", initial_balance: 1000},
      metadata: metadata
    )
  end

  defp build_meta(recorded_event) do
    Factory.build_event_handler_metadata(:account_projector, recorded_event: recorded_event)
  end

  defp build_batch_meta do
    Factory.build_batch_handler_metadata(:transaction_projector)
  end

  defp encode_traceparent(span_ctx) do
    trace_id = :otel_span.trace_id(span_ctx)
    span_id = :otel_span.span_id(span_ctx)
    trace_flags = span_ctx(span_ctx, :trace_flags)

    hex_trace_id = :io_lib.format("~32.16.0b", [trace_id]) |> IO.iodata_to_binary()
    hex_span_id = :io_lib.format("~16.16.0b", [span_id]) |> IO.iodata_to_binary()
    hex_flags = :io_lib.format("~2.16.0b", [trace_flags]) |> IO.iodata_to_binary()

    "00-#{hex_trace_id}-#{hex_span_id}-#{hex_flags}"
  end

  defp detach_handlers do
    for event <- [
          [:commanded, :event, :handle, :start],
          [:commanded, :event, :handle, :stop],
          [:commanded, :event, :handle, :exception],
          [:commanded, :event, :batch, :start],
          [:commanded, :event, :batch, :stop],
          [:commanded, :event, :batch, :exception]
        ] do
      for handler <- :telemetry.list_handlers(event) do
        :telemetry.detach(handler.id)
      end
    end
  end
end
