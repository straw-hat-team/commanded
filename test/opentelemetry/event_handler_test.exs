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

      # First call succeeds
      :ok = EventHandler.setup()

      # Verify handlers are attached
      handlers = :telemetry.list_handlers([:commanded, :event, :handle, :start])
      assert length(handlers) == 1

      # Second call raises because handlers already exist
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
      event_id = Commanded.UUID.uuid4()
      aggregate_uuid = Commanded.UUID.uuid4()
      causation_id = Commanded.UUID.uuid4()
      correlation_id = Commanded.UUID.uuid4()

      recorded_event =
        Factory.build_recorded_event(
          event_id: event_id,
          event_number: 42,
          stream_id: "BankAccount-#{aggregate_uuid}",
          stream_version: 7,
          causation_id: causation_id,
          correlation_id: correlation_id,
          event_type: "Elixir.MyApp.Events.AccountOpened",
          data: %{account_number: "ACC-001", initial_balance: 1000},
          metadata: %{}
        )

      meta =
        Factory.build_event_handler_metadata(
          application: MyApp.CommandedApp,
          handler_name: "MyApp.Projectors.AccountProjector",
          handler_module: MyApp.Projectors.AccountProjector,
          handler_state: %{},
          recorded_event: recorded_event
        )

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "MyApp.Projectors.AccountProjector receive",
                        kind: :consumer,
                        attributes: attributes
                      )},
                     1000

      attrs = :otel_attributes.map(attributes)

      # OTel Messaging SemConv
      assert attrs[:"messaging.system"] == "commanded"
      assert attrs[:"messaging.operation.type"] == :receive
      assert attrs[:"messaging.operation.name"] == "handle"
      assert attrs[:"messaging.destination.name"] == "MyApp.Projectors.AccountProjector"

      assert attrs[:"messaging.destination.subscription.name"] ==
               "MyApp.Projectors.AccountProjector"

      assert attrs[:"messaging.message.id"] == event_id
      assert attrs[:"messaging.message.conversation_id"] == correlation_id
      assert attrs[:"messaging.consumer.group.name"] == MyApp.CommandedApp

      # OTel Code SemConv
      assert attrs[:"code.function"] == "handle"
      assert attrs[:"code.namespace"] == "MyApp.Projectors.AccountProjector"

      # Commanded-specific
      assert attrs[:"commanded.application"] == MyApp.CommandedApp
      assert attrs[:"commanded.event"] == "Elixir.MyApp.Events.AccountOpened"
      assert attrs[:"commanded.event.number"] == 42
      assert attrs[:"commanded.correlation_id"] == correlation_id
      assert attrs[:"commanded.causation_id"] == causation_id
      assert attrs[:"commanded.handler.name"] == "MyApp.Projectors.AccountProjector"
      assert attrs[:"commanded.stream.id"] == "BankAccount-#{aggregate_uuid}"
      assert attrs[:"commanded.stream.version"] == 7
      assert attrs[:"commanded.handler.kind"] == "event_handler"
    end

    test "span has unset/ok status on successful handling" do
      recorded_event = build_recorded_event("success-test")
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(name: "MyApp.Projectors.AccountProjector receive", status: status)},
                     1000

      # Status should be :unset (default) for success, not :error
      assert status == :undefined or match?({:status, :unset, _}, status)
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
        Factory.build_batch_handler_metadata(
          application: MyApp.CommandedApp,
          handler_name: "MyApp.Projectors.TransactionProjector",
          handler_module: MyApp.Projectors.TransactionProjector,
          handler_state: %{processed_count: 0},
          first_event_id: first_event_id,
          last_event_id: last_event_id,
          event_count: 100,
          recorded_event: nil
        )

      :telemetry.span([:commanded, :event, :batch], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "MyApp.Projectors.TransactionProjector batch",
                        kind: :consumer,
                        attributes: attributes
                      )},
                     1000

      attrs = :otel_attributes.map(attributes)

      # OTel Messaging SemConv
      assert attrs[:"messaging.system"] == "commanded"
      assert attrs[:"messaging.operation.type"] == :receive
      assert attrs[:"messaging.operation.name"] == "batch"
      assert attrs[:"messaging.destination.name"] == "MyApp.Projectors.TransactionProjector"

      assert attrs[:"messaging.destination.subscription.name"] ==
               "MyApp.Projectors.TransactionProjector"

      assert attrs[:"messaging.consumer.group.name"] == MyApp.CommandedApp
      assert attrs[:"messaging.batch.message_count"] == 100

      # OTel Code SemConv
      assert attrs[:"code.function"] == "handle_batch"
      assert attrs[:"code.namespace"] == "MyApp.Projectors.TransactionProjector"

      # Commanded-specific
      assert attrs[:"commanded.application"] == MyApp.CommandedApp
      assert attrs[:"commanded.handler.name"] == "MyApp.Projectors.TransactionProjector"
      assert attrs[:"commanded.event.count"] == 100
      assert attrs[:"commanded.handler.kind"] == "event_handler"
      assert attrs[:"commanded.batch.first_event_id"] == first_event_id
      assert attrs[:"commanded.batch.last_event_id"] == last_event_id
    end
  end

  describe "error handling - single events" do
    setup do
      detach_handlers()
      EventHandler.setup()
      :ok
    end

    test "sets error status with error message when handler returns error" do
      recorded_event = build_recorded_event("error-test")
      meta = build_meta(recorded_event)

      :telemetry.execute([:commanded, :event, :handle, :start], %{}, meta)

      # Commanded stores only the reason, not the full {:error, reason} tuple
      # See: lib/commanded/event/handler.ex line 1073
      stop_meta = Map.put(meta, :error, :unique_constraint_violation)
      :telemetry.execute([:commanded, :event, :handle, :stop], %{duration: 1000}, stop_meta)

      assert_receive {:span,
                      span(
                        name: "MyApp.Projectors.AccountProjector receive",
                        status: {:status, :error, error_message},
                        attributes: span_attrs
                      )},
                     1000

      # Error message should contain the error reason
      assert error_message =~ "unique_constraint_violation"

      # Verify error.type SemConv attribute is set
      attrs = :otel_attributes.map(span_attrs)
      assert attrs[:"error.type"] == "unique_constraint_violation"
    end

    test "records exception event with type, message, and stacktrace" do
      recorded_event = build_recorded_event("exception-test")
      meta = build_meta(recorded_event)

      :telemetry.execute([:commanded, :event, :handle, :start], %{}, meta)

      exception_meta =
        Map.merge(meta, %{
          kind: :error,
          reason: %KeyError{key: :account_number, term: %{balance: 100}},
          stacktrace: [
            {MyApp.Projectors.AccountProjector, :handle, 2,
             [file: ~c"lib/my_app/projectors/account_projector.ex", line: 45]},
            {Commanded.Event.Handler, :delegate_event_to_handler, 2,
             [file: ~c"lib/commanded/event/handler.ex", line: 1192]}
          ]
        })

      :telemetry.execute(
        [:commanded, :event, :handle, :exception],
        %{duration: 500},
        exception_meta
      )

      assert_receive {:span,
                      span(
                        name: "MyApp.Projectors.AccountProjector receive",
                        status: {:status, :error, _},
                        attributes: span_attrs,
                        events: events
                      )},
                     1000

      # Verify error.type SemConv attribute is set on the span
      attrs = :otel_attributes.map(span_attrs)
      assert attrs[:"error.type"] == "Elixir.KeyError"

      events_list = :otel_events.list(events)
      [exception_event] = Enum.filter(events_list, fn event(name: n) -> n == :exception end)

      event(attributes: exc_attrs) = exception_event

      exc_attrs_map = :otel_attributes.map(exc_attrs)

      assert Map.has_key?(exc_attrs_map, "exception.type") or
               Map.has_key?(exc_attrs_map, :"exception.type")

      assert Map.has_key?(exc_attrs_map, "exception.message") or
               Map.has_key?(exc_attrs_map, :"exception.message")

      assert Map.has_key?(exc_attrs_map, "exception.stacktrace") or
               Map.has_key?(exc_attrs_map, :"exception.stacktrace")
    end

    test "handles throw kind - sets error status" do
      recorded_event = build_recorded_event("throw-test")
      meta = build_meta(recorded_event)

      :telemetry.execute([:commanded, :event, :handle, :start], %{}, meta)

      exception_meta =
        Map.merge(meta, %{
          kind: :throw,
          reason: :some_thrown_value,
          stacktrace: []
        })

      :telemetry.execute(
        [:commanded, :event, :handle, :exception],
        %{duration: 100},
        exception_meta
      )

      assert_receive {:span,
                      span(
                        name: "MyApp.Projectors.AccountProjector receive",
                        status: {:status, :error, error_msg}
                      )},
                     1000

      assert error_msg =~ "some_thrown_value"
    end

    test "handles exit kind exceptions" do
      recorded_event = build_recorded_event("exit-test")
      meta = build_meta(recorded_event)

      :telemetry.execute([:commanded, :event, :handle, :start], %{}, meta)

      exception_meta =
        Map.merge(meta, %{
          kind: :exit,
          reason: :normal,
          stacktrace: []
        })

      :telemetry.execute(
        [:commanded, :event, :handle, :exception],
        %{duration: 100},
        exception_meta
      )

      assert_receive {:span,
                      span(
                        name: "MyApp.Projectors.AccountProjector receive",
                        status: {:status, :error, _}
                      )},
                     1000
    end
  end

  describe "error handling - batch events" do
    setup do
      detach_handlers()
      EventHandler.setup()
      :ok
    end

    test "sets error status when batch handler returns error" do
      meta = build_batch_meta()

      :telemetry.execute([:commanded, :event, :batch, :start], %{}, meta)

      stop_meta = Map.put(meta, :error, :transaction_rollback)
      :telemetry.execute([:commanded, :event, :batch, :stop], %{duration: 2000}, stop_meta)

      assert_receive {:span,
                      span(
                        name: "MyApp.Projectors.TransactionProjector batch",
                        status: {:status, :error, error_message}
                      )},
                     1000

      assert error_message =~ "transaction_rollback"
    end

    test "records exception in batch handler" do
      meta = build_batch_meta()

      :telemetry.execute([:commanded, :event, :batch, :start], %{}, meta)

      exception_meta =
        Map.merge(meta, %{
          kind: :error,
          reason: %DBConnection.ConnectionError{message: "connection refused"},
          stacktrace: []
        })

      :telemetry.execute(
        [:commanded, :event, :batch, :exception],
        %{duration: 100},
        exception_meta
      )

      assert_receive {:span,
                      span(
                        name: "MyApp.Projectors.TransactionProjector batch",
                        status: {:status, :error, _},
                        events: events
                      )},
                     1000

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
                        name: "MyApp.Projectors.AccountProjector receive",
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
                        name: "MyApp.Projectors.AccountProjector receive",
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
                        name: "MyApp.Projectors.AccountProjector receive",
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
                        name: "MyApp.Projectors.AccountProjector receive",
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
      # This tests the fix for the issue where :link mode didn't clear existing context
      # before creating spans. If other OTel instrumentation set context in the same
      # process, spans would have unintended parents.

      # First, set up a "stale" context as if another instrumentation left it
      stale_traceparent =
        Tracer.with_span "stale.context.span" do
          encode_traceparent(Tracer.current_span_ctx())
        end

      # Manually set stale context in process dictionary (simulating other instrumentation)
      stale_headers = [{"traceparent", stale_traceparent}]
      stale_ctx = :otel_propagator_text_map.extract_to(:otel_ctx.new(), stale_headers)
      :otel_ctx.attach(stale_ctx)

      # Now dispatch event WITHOUT traceparent (common case for events not from commands)
      recorded_event = build_recorded_event("stale-context-test", %{})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "MyApp.Projectors.AccountProjector receive",
                        parent_span_id: parent_id
                      )},
                     1000

      # The span should NOT have a parent - it should start a fresh trace
      # This is the key assertion: :link mode should NOT inherit stale context
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
                        name: "MyApp.Projectors.AccountProjector receive",
                        trace_id: span_trace_id,
                        parent_span_id: :undefined,
                        links: links
                      )},
                     1000

      # The span should have its OWN trace_id (not the linked one)
      refute span_trace_id == linked_trace_id

      # Should have exactly one link
      [link(trace_id: link_trace_id, span_id: link_span_id)] = :otel_links.list(links)

      # The link should point to the original span
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
                        name: "MyApp.Projectors.AccountProjector receive",
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
                        name: "MyApp.Projectors.AccountProjector receive",
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
                        name: "MyApp.Projectors.TransactionProjector batch",
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
                        name: "MyApp.Projectors.TransactionProjector batch",
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
                        name: "MyApp.Projectors.AccountProjector receive",
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
                        name: "MyApp.Projectors.AccountProjector receive",
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
                        name: "MyApp.Projectors.AccountProjector receive",
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
                        name: "MyApp.Projectors.TransactionProjector batch",
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
      recorded_event = build_recorded_event("nil-module")

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
                        name: "TestHandler receive",
                        attributes: attributes
                      )},
                     1000

      attrs = :otel_attributes.map(attributes)
      assert attrs[:"code.namespace"] == nil
      assert attrs[:"messaging.destination.name"] == nil
    end

    test "handles empty metadata map in recorded_event" do
      recorded_event = build_recorded_event("empty-meta", %{})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span, span(name: "MyApp.Projectors.AccountProjector receive")}, 1000
    end

    test "handles metadata with only tracestate (no traceparent)" do
      recorded_event = build_recorded_event("only-tracestate", %{"tracestate" => "vendor=value"})
      meta = build_meta(recorded_event)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "MyApp.Projectors.AccountProjector receive",
                        parent_span_id: :undefined
                      )},
                     1000
    end
  end

  defp build_recorded_event(suffix, metadata \\ %{}) do
    Factory.build_recorded_event(
      stream_id: "BankAccount-#{Commanded.UUID.uuid4()}",
      event_type: "Elixir.MyApp.Events.AccountOpened",
      data: %{account_number: "ACC-#{suffix}", initial_balance: 1000},
      metadata: metadata
    )
  end

  defp build_meta(recorded_event) do
    Factory.build_event_handler_metadata(
      application: MyApp.CommandedApp,
      handler_name: "MyApp.Projectors.AccountProjector",
      handler_module: MyApp.Projectors.AccountProjector,
      handler_state: %{},
      recorded_event: recorded_event
    )
  end

  defp build_batch_meta do
    Factory.build_batch_handler_metadata(
      application: MyApp.CommandedApp,
      handler_name: "MyApp.Projectors.TransactionProjector",
      handler_module: MyApp.Projectors.TransactionProjector,
      handler_state: %{processed_count: 0},
      event_count: 10
    )
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
