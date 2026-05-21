defmodule Commanded.Middleware.BaggagePropagatorTest do
  use ExUnit.Case, async: false

  alias Commanded.Middleware.BaggagePropagator
  alias Commanded.Middleware.Commands.Fail
  alias Commanded.Middleware.Pipeline

  setup do
    on_exit(fn -> :otel_baggage.clear() end)
    :otel_baggage.clear()
    :ok
  end

  describe "before_dispatch/1" do
    test "does not modify metadata when no baggage is set" do
      pipeline = %Pipeline{command: %Fail{}, metadata: %{}}

      result = BaggagePropagator.before_dispatch(pipeline)

      assert result.metadata == %{}
    end

    test "captures baggage when present on the current context" do
      :otel_baggage.set(%{"userId" => "alice", "tenant" => "acme"})

      pipeline = %Pipeline{command: %Fail{}, metadata: %{}}

      result = BaggagePropagator.before_dispatch(pipeline)

      assert %{"baggage" => header} = result.metadata
      assert header =~ "userId=alice"
      assert header =~ "tenant=acme"
    end

    test "preserves existing metadata" do
      :otel_baggage.set(%{"userId" => "alice"})

      pipeline = %Pipeline{
        command: %Fail{},
        metadata: %{"correlation_id" => "abc-123"}
      }

      result = BaggagePropagator.before_dispatch(pipeline)

      assert result.metadata["correlation_id"] == "abc-123"
      assert result.metadata["baggage"] =~ "userId=alice"
    end

    test "does not modify pipeline command" do
      :otel_baggage.set(%{"userId" => "alice"})

      command = %Fail{}
      pipeline = %Pipeline{command: command, metadata: %{}}

      result = BaggagePropagator.before_dispatch(pipeline)

      assert result.command == command
    end

    test "does not modify pipeline assigns" do
      :otel_baggage.set(%{"userId" => "alice"})

      pipeline = %Pipeline{
        command: %Fail{},
        metadata: %{},
        assigns: %{existing: "value"}
      }

      result = BaggagePropagator.before_dispatch(pipeline)

      assert result.assigns == %{existing: "value"}
    end

    test "round-trips through W3C baggage decoding" do
      :otel_baggage.set(%{"userId" => "alice", "tenant" => "acme"})

      pipeline = %Pipeline{command: %Fail{}, metadata: %{}}

      result = BaggagePropagator.before_dispatch(pipeline)

      ctx =
        :otel_ctx.new()
        |> :otel_propagator_text_map.extract_to([{"baggage", result.metadata["baggage"]}])

      decoded = :otel_baggage.get_all(ctx)

      assert decoded["userId"] == {"alice", []}
      assert decoded["tenant"] == {"acme", []}
    end
  end

  describe "after_dispatch/1" do
    test "returns pipeline unchanged" do
      pipeline = %Pipeline{command: %Fail{}, metadata: %{"test" => "value"}}

      assert BaggagePropagator.after_dispatch(pipeline) == pipeline
    end
  end

  describe "after_failure/1" do
    test "returns pipeline unchanged" do
      pipeline = %Pipeline{command: %Fail{}, metadata: %{"test" => "value"}}

      assert BaggagePropagator.after_failure(pipeline) == pipeline
    end
  end
end
