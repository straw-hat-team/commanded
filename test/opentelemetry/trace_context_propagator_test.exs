defmodule Commanded.Middleware.TraceContextPropagatorTest do
  use ExUnit.Case, async: true

  alias Commanded.Middleware.Commands.Fail
  alias Commanded.Middleware.Pipeline
  alias Commanded.Middleware.TraceContextPropagator

  require OpenTelemetry.Tracer, as: Tracer

  @trace_id "0af7651916cd43dd8448eb211c80319c"
  @span_id "b7ad6b7169203331"
  @traceparent "00-#{@trace_id}-#{@span_id}-01"
  @tracestate "vendor1=value1,vendor2=value2"

  describe "before_dispatch/1" do
    test "captures traceparent when span context is active" do
      set_trace_context(@traceparent)

      pipeline = %Pipeline{command: %Fail{}, metadata: %{}}

      result = TraceContextPropagator.before_dispatch(pipeline)

      assert result.metadata == %{"traceparent" => @traceparent}
    end

    test "does not modify metadata when no span is active" do
      pipeline = %Pipeline{command: %Fail{}, metadata: %{}}

      result = TraceContextPropagator.before_dispatch(pipeline)

      assert result.metadata == %{}
    end

    test "preserves existing metadata" do
      set_trace_context(@traceparent)

      pipeline = %Pipeline{
        command: %Fail{},
        metadata: %{"user_id" => "123", "tenant" => "acme"}
      }

      result = TraceContextPropagator.before_dispatch(pipeline)

      assert result.metadata == %{
               "user_id" => "123",
               "tenant" => "acme",
               "traceparent" => @traceparent
             }
    end

    test "does not set tracestate when span has no tracestate" do
      set_trace_context(@traceparent)

      pipeline = %Pipeline{command: %Fail{}, metadata: %{}}

      result = TraceContextPropagator.before_dispatch(pipeline)

      assert result.metadata == %{"traceparent" => @traceparent}
    end

    test "captures tracestate when present in span context" do
      set_trace_context(@traceparent, @tracestate)

      pipeline = %Pipeline{command: %Fail{}, metadata: %{}}

      result = TraceContextPropagator.before_dispatch(pipeline)

      assert result.metadata == %{
               "traceparent" => @traceparent,
               "tracestate" => @tracestate
             }
    end

    test "child span inherits trace_id and tracestate from parent" do
      set_trace_context(@traceparent, "vendor=parentvalue")

      Tracer.with_span "child.span" do
        pipeline = %Pipeline{command: %Fail{}, metadata: %{}}

        result = TraceContextPropagator.before_dispatch(pipeline)

        # Extract child's span_id (dynamic)
        "00-" <> @trace_id <> "-" <> rest = result.metadata["traceparent"]
        [child_span_id, "01"] = String.split(rest, "-")

        assert result.metadata == %{
                 "traceparent" => "00-#{@trace_id}-#{child_span_id}-01",
                 "tracestate" => "vendor=parentvalue"
               }

        # Span ID should be different from parent's
        refute child_span_id == @span_id
      end
    end

    test "does not modify pipeline command" do
      set_trace_context(@traceparent)

      command = %Fail{}
      pipeline = %Pipeline{command: command, metadata: %{}}

      result = TraceContextPropagator.before_dispatch(pipeline)

      assert result.command == command
      assert result.metadata == %{"traceparent" => @traceparent}
    end

    test "does not modify pipeline assigns" do
      set_trace_context(@traceparent)

      pipeline = %Pipeline{
        command: %Fail{},
        metadata: %{},
        assigns: %{existing: "value"}
      }

      result = TraceContextPropagator.before_dispatch(pipeline)

      assert result.assigns == %{existing: "value"}
      assert result.metadata == %{"traceparent" => @traceparent}
    end
  end

  describe "after_dispatch/1" do
    test "returns pipeline unchanged" do
      pipeline = %Pipeline{command: %Fail{}, metadata: %{"test" => "value"}}

      assert TraceContextPropagator.after_dispatch(pipeline) == pipeline
    end
  end

  describe "after_failure/1" do
    test "returns pipeline unchanged" do
      pipeline = %Pipeline{command: %Fail{}, metadata: %{"test" => "value"}}

      assert TraceContextPropagator.after_failure(pipeline) == pipeline
    end
  end

  defp set_trace_context(traceparent) when is_binary(traceparent) do
    :otel_propagator_text_map.extract([{"traceparent", traceparent}])
  end

  defp set_trace_context(traceparent, tracestate)
       when is_binary(traceparent) and is_binary(tracestate) do
    :otel_propagator_text_map.extract([
      {"traceparent", traceparent},
      {"tracestate", tracestate}
    ])
  end
end
