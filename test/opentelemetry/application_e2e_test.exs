defmodule Commanded.OpenTelemetry.ApplicationE2ETest do
  use Commanded.OpenTelemetryCase, async: false

  @moduletag :eventstore_adapter

  alias Commanded.Middleware.Commands.IncrementCount
  alias Commanded.OpenTelemetry.Aggregate, as: OTelAggregate
  alias Commanded.OpenTelemetry.Application, as: OTelApplication
  alias Commanded.OpenTelemetry.EventHandler, as: OTelEventHandler
  alias Commanded.UUID

  require OpenTelemetry.Tracer, as: Tracer

  defmodule E2ERouter do
    use Commanded.Commands.Router

    alias Commanded.Middleware.Commands.CommandHandler
    alias Commanded.Middleware.Commands.CounterAggregateRoot

    middleware Commanded.Middleware.TraceContextPropagator

    dispatch IncrementCount,
      to: CommandHandler,
      aggregate: CounterAggregateRoot,
      identity: :aggregate_uuid
  end

  defmodule App do
    use Commanded.Application,
      otp_app: :commanded,
      event_store: [
        adapter: Commanded.EventStore.Adapters.EventStore,
        event_store: TestEventStore
      ],
      pubsub: :local,
      registry: :local

    router(E2ERouter)
  end

  defmodule E2EEventHandler do
    use Commanded.Event.Handler,
      application: Commanded.OpenTelemetry.ApplicationE2ETest.App,
      name: __MODULE__

    def handle(_event, _metadata), do: :ok
  end

  setup do
    start_event_store()
    start_supervised!(App)
    detach_all_handlers()
    OTelApplication.setup()
    OTelAggregate.setup()
    OTelEventHandler.setup(span_relationship: :link)
    start_supervised!(E2EEventHandler)
    :ok
  end

  test "dispatch and aggregate are children, event handler is linked" do
    aggregate_uuid = UUID.uuid4()

    {http_trace_id, http_span_id} =
      Tracer.with_span "http.server.request" do
        ctx = Tracer.current_span_ctx()
        trace_id = :otel_span.trace_id(ctx)
        span_id = :otel_span.span_id(ctx)

        :ok = App.dispatch(%IncrementCount{aggregate_uuid: aggregate_uuid})

        {trace_id, span_id}
      end

    spans = collect_spans_until(["dispatch", "execute", "handle"])

    dispatch_span = find_span_prefix(spans, "dispatch")
    execute_span = find_span_prefix(spans, "execute")
    handle_span = find_span_prefix(spans, "handle")

    assert span(dispatch_span, :trace_id) == http_trace_id
    assert span(dispatch_span, :parent_span_id) == http_span_id

    dispatch_span_id = span(dispatch_span, :span_id)
    assert span(execute_span, :trace_id) == http_trace_id
    assert span(execute_span, :parent_span_id) == dispatch_span_id

    assert span(handle_span, :trace_id) != http_trace_id,
           "Event handler should start a new trace, not join the original"

    assert span(handle_span, :parent_span_id) == :undefined,
           "Event handler should have no parent (root of its own trace)"

    [first_link | _] = :otel_links.list(span(handle_span, :links))

    assert link(first_link, :trace_id) == http_trace_id,
           "Event handler link should reference the original trace"

    assert link(first_link, :span_id) == dispatch_span_id,
           "Event handler link should point to the dispatch span"
  end

  test "dispatch telemetry metadata has no traceparent (middleware runs after)" do
    aggregate_uuid = UUID.uuid4()
    test_pid = self()

    :telemetry.attach(
      "metadata-spy-dispatch",
      [:commanded, :application, :dispatch, :start],
      fn _event, _measurements, meta, _config ->
        send(test_pid, {:dispatch_metadata, meta.execution_context.metadata})
      end,
      nil
    )

    :telemetry.attach(
      "metadata-spy-aggregate",
      [:commanded, :aggregate, :execute, :start],
      fn _event, _measurements, meta, _config ->
        send(test_pid, {:aggregate_metadata, meta.execution_context.metadata})
      end,
      nil
    )

    Tracer.with_span "http.server.request" do
      :ok = App.dispatch(%IncrementCount{aggregate_uuid: aggregate_uuid})
    end

    assert_receive {:dispatch_metadata, dispatch_meta}, 1000
    assert_receive {:aggregate_metadata, aggregate_meta}, 1000

    refute Map.has_key?(dispatch_meta, "traceparent"),
           "dispatch :start should NOT have traceparent (middleware hasn't run yet)"

    assert Map.has_key?(aggregate_meta, "traceparent"),
           "aggregate :start should have traceparent (middleware already ran)"

    :telemetry.detach("metadata-spy-dispatch")
    :telemetry.detach("metadata-spy-aggregate")
  end

  defp start_event_store do
    alias Commanded.EventStore.Adapters.EventStore.Storage

    config = Storage.config()

    on_exit(fn ->
      {:ok, conn} = Storage.connect(config)
      Storage.reset!(conn, config)
    end)
  end

  defp find_span_prefix(spans, prefix) do
    Enum.find(spans, fn s -> String.starts_with?(span(s, :name), prefix) end)
  end

  defp collect_spans_until(expected_prefixes, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_spans_until([], expected_prefixes, deadline)
  end

  defp collect_spans_until(acc, expected_prefixes, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if has_all_prefixes?(acc, expected_prefixes) do
      Enum.reverse(acc)
    else
      receive do
        {:span, s} -> collect_spans_until([s | acc], expected_prefixes, deadline)
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  defp has_all_prefixes?(spans, prefixes) do
    Enum.all?(prefixes, fn prefix ->
      Enum.any?(spans, fn s -> String.starts_with?(span(s, :name), prefix) end)
    end)
  end

  defp detach_all_handlers do
    commanded_events = [
      [:commanded, :application, :dispatch, :start],
      [:commanded, :application, :dispatch, :stop],
      [:commanded, :application, :dispatch, :exception],
      [:commanded, :aggregate, :execute, :start],
      [:commanded, :aggregate, :execute, :stop],
      [:commanded, :aggregate, :execute, :exception],
      [:commanded, :event, :handle, :start],
      [:commanded, :event, :handle, :stop],
      [:commanded, :event, :handle, :exception]
    ]

    for event <- commanded_events,
        handler <- :telemetry.list_handlers(event) do
      :telemetry.detach(handler.id)
    end
  end
end
