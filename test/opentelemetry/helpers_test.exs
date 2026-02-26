defmodule Commanded.OpenTelemetry.HelpersTest do
  use Commanded.OpenTelemetryCase, async: false

  alias Commanded.OpenTelemetry.Helpers

  require OpenTelemetry.Tracer, as: Tracer

  describe "extract_propagated_ctx/1" do
    test "returns {[], :undefined} for nil metadata" do
      assert {[], :undefined} = Helpers.extract_propagated_ctx(nil)
    end

    test "returns {[], :undefined} for empty metadata map" do
      assert {[], :undefined} = Helpers.extract_propagated_ctx(%{})
    end

    test "returns {[], :undefined} for metadata without traceparent" do
      assert {[], :undefined} = Helpers.extract_propagated_ctx(%{"foo" => "bar"})
    end

    test "returns {[], :undefined} for invalid traceparent" do
      assert {[], :undefined} = Helpers.extract_propagated_ctx(%{"traceparent" => "not-valid"})
    end

    test "returns {links, ctx} for valid traceparent" do
      {expected_trace_id, expected_span_id, traceparent} = make_traceparent()

      {links, ctx} = Helpers.extract_propagated_ctx(%{"traceparent" => traceparent})

      refute ctx == :undefined

      assert [%{trace_id: ^expected_trace_id, span_id: ^expected_span_id}] = links
    end

    test "returned ctx contains the extracted span context" do
      {expected_trace_id, expected_span_id, traceparent} = make_traceparent()

      {_links, ctx} = Helpers.extract_propagated_ctx(%{"traceparent" => traceparent})

      span_ctx = :otel_tracer.current_span_ctx(ctx)
      assert :otel_span.trace_id(span_ctx) == expected_trace_id
      assert :otel_span.span_id(span_ctx) == expected_span_id
    end

    test "handles traceparent with tracestate" do
      {expected_trace_id, _span_id, traceparent} = make_traceparent()

      metadata = %{
        "traceparent" => traceparent,
        "tracestate" => "vendor=opaque"
      }

      {links, ctx} = Helpers.extract_propagated_ctx(metadata)

      refute ctx == :undefined
      assert [%{trace_id: ^expected_trace_id}] = links
    end

    test "does not attach the extracted context to the process dictionary" do
      before_ctx = :otel_ctx.get_current()

      {_links, _ctx} = make_traceparent() |> make_metadata() |> Helpers.extract_propagated_ctx()

      after_ctx = :otel_ctx.get_current()
      assert before_ctx == after_ctx
    end
  end

  describe "clear_ctx/0" do
    test "replaces current context with an empty one" do
      {_links, ctx} = make_traceparent() |> make_metadata() |> Helpers.extract_propagated_ctx()
      :otel_ctx.attach(ctx)

      span_before = :otel_tracer.current_span_ctx()
      refute span_before == :undefined

      Helpers.clear_ctx()

      span_after = :otel_tracer.current_span_ctx()
      refute :otel_span.is_valid(span_after)
    end

    test "clears stale context from a previous attach" do
      stale_traceparent =
        Tracer.with_span "stale.span" do
          encode_traceparent(Tracer.current_span_ctx())
        end

      stale_headers = [{"traceparent", stale_traceparent}]
      stale_ctx = :otel_propagator_text_map.extract_to(:otel_ctx.new(), stale_headers)
      :otel_ctx.attach(stale_ctx)

      assert :otel_span.is_valid(:otel_tracer.current_span_ctx())

      Helpers.clear_ctx()

      refute :otel_span.is_valid(:otel_tracer.current_span_ctx())
    end
  end

  describe "extract_propagated_ctx + clear_ctx integration" do
    test ":link pattern — extract links then clear context" do
      {expected_trace_id, expected_span_id, traceparent} = make_traceparent()

      {links, _ctx} = Helpers.extract_propagated_ctx(%{"traceparent" => traceparent})
      Helpers.clear_ctx()

      assert [%{trace_id: ^expected_trace_id, span_id: ^expected_span_id}] = links

      refute :otel_span.is_valid(:otel_tracer.current_span_ctx())
    end

    test ":child pattern — extract and attach valid context" do
      {expected_trace_id, _span_id, traceparent} = make_traceparent()

      case Helpers.extract_propagated_ctx(%{"traceparent" => traceparent}) do
        {_links, :undefined} -> Helpers.clear_ctx()
        {_links, ctx} -> :otel_ctx.attach(ctx)
      end

      span_ctx = :otel_tracer.current_span_ctx()
      assert :otel_span.is_valid(span_ctx)
      assert :otel_span.trace_id(span_ctx) == expected_trace_id
    end

    test ":child pattern — clear context when no valid traceparent" do
      stale_headers = [{"traceparent", make_traceparent() |> elem(2)}]
      stale_ctx = :otel_propagator_text_map.extract_to(:otel_ctx.new(), stale_headers)
      :otel_ctx.attach(stale_ctx)

      case Helpers.extract_propagated_ctx(%{}) do
        {_links, :undefined} -> Helpers.clear_ctx()
        {_links, ctx} -> :otel_ctx.attach(ctx)
      end

      refute :otel_span.is_valid(:otel_tracer.current_span_ctx())
    end

    test ":none pattern — always clear regardless of metadata" do
      {_trace_id, _span_id, traceparent} = make_traceparent()

      Helpers.clear_ctx()

      refute :otel_span.is_valid(:otel_tracer.current_span_ctx())

      stale_headers = [{"traceparent", traceparent}]
      stale_ctx = :otel_propagator_text_map.extract_to(:otel_ctx.new(), stale_headers)
      :otel_ctx.attach(stale_ctx)

      Helpers.clear_ctx()

      refute :otel_span.is_valid(:otel_tracer.current_span_ctx())
    end
  end

  defp make_traceparent do
    Tracer.with_span "test.parent.span" do
      ctx = Tracer.current_span_ctx()

      {
        :otel_span.trace_id(ctx),
        :otel_span.span_id(ctx),
        encode_traceparent(ctx)
      }
    end
  end

  defp make_metadata({_trace_id, _span_id, traceparent}) do
    %{"traceparent" => traceparent}
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
end
