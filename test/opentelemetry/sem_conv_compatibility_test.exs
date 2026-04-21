defmodule Commanded.OpenTelemetry.SemConvCompatibilityTest do
  use Commanded.OpenTelemetryCase, async: false

  import Commanded.TestSupport.Factory

  alias Commanded.Application, as: CommandedApplication
  alias Commanded.DefaultApp
  alias Commanded.EventStore
  alias Commanded.EventStore.AdapterTestData
  alias Commanded.OpenTelemetry
  alias Commanded.OpenTelemetry.Application, as: OTelApplication
  alias Commanded.OpenTelemetry.EventHandler
  alias Commanded.OpenTelemetry.EventStore, as: OTelEventStore
  alias Commanded.UUID

  setup do
    start_supervised!(DefaultApp)

    :ok
  end

  describe "messaging SemConv compatibility" do
    test "application spans become internal when messaging opt-in is enabled" do
      put_semconv_stability_opt_in("messaging")

      detach_application_handlers()
      OTelApplication.setup()

      meta = build_application_dispatch_metadata()

      :telemetry.execute([:commanded, :application, :dispatch, :start], %{}, meta)
      :telemetry.execute([:commanded, :application, :dispatch, :stop], %{duration: 1000}, meta)

      assert_receive {:span,
                      span(
                        name: "dispatch Commanded.TestSupport.TestDomain.Account",
                        kind: :internal,
                        attributes: attributes
                      )},
                     1000

      attrs = :otel_attributes.map(attributes)

      assert attrs[:"code.function.name"] == "Commanded.TestSupport.TestDomain.Account.execute"
      refute Enum.any?(Map.keys(attrs), &String.starts_with?(to_string(&1), "messaging."))
    end

    test "event handler duplicate mode keeps legacy destination names but switches to stable operation type" do
      put_semconv_stability_opt_in("messaging/dup")

      detach_event_handler_handlers()
      EventHandler.setup()

      meta = build_event_handler_metadata(:account_projector)

      :telemetry.span([:commanded, :event, :handle], meta, fn ->
        {:ok, %{processing_latency_ms: 25}, meta}
      end)

      assert_receive {:span,
                      span(
                        name: "handle MyApp.Projectors.AccountProjector",
                        kind: :consumer,
                        attributes: attributes
                      )},
                     1000

      attrs = :otel_attributes.map(attributes)

      assert attrs[:"messaging.operation.type"] == "process"
      assert attrs[:"messaging.destination.name"] == "MyApp.Projectors.AccountProjector"

      assert attrs[:"messaging.destination.subscription.name"] ==
               "MyApp.Projectors.AccountProjector"

      assert attrs[:"code.function.name"] == "MyApp.Projectors.AccountProjector.handle"
    end
  end

  describe "database SemConv compatibility" do
    test "event store spans emit stable database attrs in database mode" do
      put_semconv_stability_opt_in("database")

      detach_event_store_handlers()
      OTelEventStore.setup()

      destination_name = expected_event_store_destination(DefaultApp)
      span_name = "append_to_stream #{destination_name}"
      stream_uuid = UUID.uuid4()

      assert :ok = EventStore.append_to_stream(DefaultApp, stream_uuid, 0, build_events(1))

      assert_receive {:span,
                      span(
                        name: ^span_name,
                        kind: :client,
                        attributes: attributes
                      )},
                     1000

      attrs = :otel_attributes.map(attributes)

      assert attrs[:"db.system.name"] == "in_memory"
      assert attrs[:"db.operation.name"] == "append_to_stream"
      assert attrs[:"code.function.name"] == "Commanded.EventStore.append_to_stream"
      refute Map.has_key?(attrs, :"db.system")
      refute Map.has_key?(attrs, :"db.namespace")
      refute Map.has_key?(attrs, :"messaging.system")
      refute Map.has_key?(attrs, :"service.peer.name")
    end

    test "event store duplicate mode emits both legacy and stable database attrs" do
      put_semconv_stability_opt_in("database/dup")

      detach_event_store_handlers()
      OTelEventStore.setup()

      destination_name = expected_event_store_destination(DefaultApp)
      span_name = "append_to_stream #{destination_name}"
      stream_uuid = UUID.uuid4()

      assert :ok = EventStore.append_to_stream(DefaultApp, stream_uuid, 0, build_events(1))

      assert_receive {:span,
                      span(
                        name: ^span_name,
                        kind: :client,
                        attributes: attributes
                      )},
                     1000

      attrs = :otel_attributes.map(attributes)

      assert attrs[:"db.system"] == :in_memory
      assert attrs[:"db.system.name"] == "in_memory"
      assert attrs[:"db.operation.name"] == "append_to_stream"
      assert attrs[:"messaging.system"] == "commanded"
      assert attrs[:"messaging.operation.type"] == :publish
      refute Map.has_key?(attrs, :"service.peer.name")
    end
  end

  describe "exception signal compatibility" do
    test "setup warns when exception signal opt-in is requested but unsupported" do
      put_exception_signal_opt_in("logs")

      handler_id = attach_warning_handler()
      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok =
               OpenTelemetry.setup(
                 aggregate: :disabled,
                 aggregate_populate: :disabled,
                 aggregate_snapshot: :disabled,
                 application: :disabled,
                 event_handler: :disabled,
                 event_store: :disabled
               )

      assert_receive {:warning, [:commanded, :opentelemetry, :warning], %{count: 1},
                      %{
                        message:
                          "OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN is not supported; Commanded continues recording exceptions as span events",
                        requested_opt_in: "logs",
                        tracer_id: OpenTelemetry
                      }}
    end
  end

  defp expected_event_store_destination(application) do
    {_adapter, adapter_meta} = CommandedApplication.event_store_adapter(application)
    destination_name = Map.get(adapter_meta, :name) || Map.get(adapter_meta, :event_store)

    to_expected_destination_name(destination_name)
  end

  defp to_expected_destination_name(nil), do: nil
  defp to_expected_destination_name(name) when is_binary(name), do: name
  defp to_expected_destination_name(name) when is_atom(name), do: inspect(name)
  defp to_expected_destination_name(_), do: nil

  defp build_events(count), do: AdapterTestData.build_opened_events(count)

  defp detach_application_handlers do
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

  defp detach_event_handler_handlers do
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

  defp detach_event_store_handlers do
    for event <- [
          :append_to_stream,
          :delete_snapshot,
          :read_snapshot,
          :record_snapshot,
          :stream_forward
        ] do
      for suffix <- [:start, :stop, :exception] do
        for handler <- :telemetry.list_handlers([:commanded, :event_store, event, suffix]) do
          :telemetry.detach(handler.id)
        end
      end
    end
  end

  defp attach_warning_handler do
    handler_id = {__MODULE__, :warning, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:commanded, :opentelemetry, :warning],
        &__MODULE__.handle_warning/4,
        self()
      )

    handler_id
  end

  def handle_warning(event, measurements, meta, pid) do
    send(pid, {:warning, event, measurements, meta})
  end
end
