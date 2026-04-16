defmodule Commanded.OpenTelemetry.EventStore do
  @moduledoc false

  alias Commanded.Application, as: CommandedApplication
  alias Commanded.OpenTelemetry.CommandedAttributes
  alias Commanded.OpenTelemetry.Helpers
  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.CodeAttributes
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes
  alias OpenTelemetry.Span

  @tracer_id __MODULE__

  @events ~w(
    ack_event
    append_to_stream
    delete_snapshot
    delete_subscription
    read_snapshot
    record_snapshot
    stream_forward
    subscribe
    subscribe_to
    unsubscribe
  )a

  def setup do
    for event <- @events do
      :ok =
        :telemetry.attach_many(
          {__MODULE__, event},
          [
            [:commanded, :event_store, event, :start],
            [:commanded, :event_store, event, :stop],
            [:commanded, :event_store, event, :exception]
          ],
          &__MODULE__.handle_telemetry_event/4,
          %{}
        )
    end

    :ok
  end

  def handle_telemetry_event(
        [:commanded, :event_store, action, :start],
        _measurements,
        meta,
        _config
      ) do
    operation_type = operation_type_for(action)
    action_name = to_string(action)
    destination_name = event_store_destination_name(meta)
    source_uuid = extract_source_uuid(meta)

    attributes =
      [
        {MessagingAttributes.messaging_system(), "commanded"},
        {MessagingAttributes.messaging_operation_name(), action_name},
        {CodeAttributes.code_function(), action_name},
        {CommandedAttributes.commanded_application(), meta[:application]}
      ]
      |> maybe_add_operation_type(operation_type)
      |> maybe_add_destination_name(destination_name)
      |> maybe_add_stream_uuid(meta[:stream_uuid])
      |> maybe_add_expected_version(meta[:expected_version])
      |> maybe_add_subscription_name(meta[:subscription_name])
      |> maybe_add_source_uuid(source_uuid)
      |> maybe_add_start_from(meta[:start_from])

    span_name =
      case destination_name do
        nil -> action_name
        name -> "#{action_name} #{name}"
      end

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      span_name,
      meta,
      %{
        kind: :internal,
        attributes: attributes
      }
    )
  end

  def handle_telemetry_event(
        [:commanded, :event_store, _action, :stop],
        _measurements,
        meta,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    if error = meta[:error] do
      Span.set_attribute(
        ctx,
        ErrorAttributes.error_type(),
        Helpers.to_error_type(error, @tracer_id)
      )

      Span.set_status(ctx, OpenTelemetry.status(:error, Helpers.format_error(error)))
    end

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  def handle_telemetry_event(
        [:commanded, :event_store, _action, :exception],
        _measurements,
        %{kind: kind, reason: reason, stacktrace: stacktrace} = meta,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    # TODO: follow up with OTEL team to add exception.kind SemConv attribute
    Span.set_attribute(ctx, :"erlang.exception.kind", kind)

    exception = Exception.normalize(kind, reason, stacktrace)

    Span.set_attribute(
      ctx,
      ErrorAttributes.error_type(),
      Helpers.to_error_type(exception, @tracer_id)
    )

    Span.record_exception(ctx, exception, stacktrace)

    Span.set_status(
      ctx,
      OpenTelemetry.status(:error, Exception.format_banner(kind, reason, stacktrace))
    )

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  defp operation_type_for(:append_to_stream), do: :publish
  defp operation_type_for(:stream_forward), do: :receive
  defp operation_type_for(:subscribe), do: :receive
  defp operation_type_for(:subscribe_to), do: :receive
  defp operation_type_for(:ack_event), do: :settle
  defp operation_type_for(:delete_snapshot), do: nil
  defp operation_type_for(:delete_subscription), do: nil
  defp operation_type_for(:read_snapshot), do: :receive
  defp operation_type_for(:record_snapshot), do: :publish
  defp operation_type_for(:unsubscribe), do: nil
  defp operation_type_for(_), do: nil

  defp maybe_add_operation_type(attrs, nil), do: attrs

  defp maybe_add_operation_type(attrs, type),
    do: [{MessagingAttributes.messaging_operation_type(), type} | attrs]

  defp maybe_add_destination_name(attrs, nil), do: attrs

  defp maybe_add_destination_name(attrs, destination_name),
    do: [{MessagingAttributes.messaging_destination_name(), destination_name} | attrs]

  defp maybe_add_stream_uuid(attrs, nil), do: attrs

  defp maybe_add_stream_uuid(attrs, stream_uuid),
    do: [{CommandedAttributes.commanded_stream_uuid(), stream_uuid} | attrs]

  defp maybe_add_expected_version(attrs, nil), do: attrs

  defp maybe_add_expected_version(attrs, expected_version),
    do: [{CommandedAttributes.commanded_expected_version(), expected_version} | attrs]

  defp maybe_add_subscription_name(attrs, nil), do: attrs

  defp maybe_add_subscription_name(attrs, name) do
    [
      {MessagingAttributes.messaging_destination_subscription_name(), name},
      {CommandedAttributes.commanded_subscription_name(), name}
      | attrs
    ]
  end

  defp maybe_add_source_uuid(attrs, nil), do: attrs

  defp maybe_add_source_uuid(attrs, source_uuid),
    do: [{CommandedAttributes.commanded_source_uuid(), source_uuid} | attrs]

  defp maybe_add_start_from(attrs, nil), do: attrs

  defp maybe_add_start_from(attrs, start_from),
    do: [{CommandedAttributes.commanded_start_from(), to_start_from_attr(start_from)} | attrs]

  # Extract source_uuid from metadata or nested snapshot struct (record_snapshot operation)
  defp extract_source_uuid(%{source_uuid: uuid}) when is_binary(uuid), do: uuid
  defp extract_source_uuid(%{snapshot: %{source_uuid: uuid}}) when is_binary(uuid), do: uuid
  defp extract_source_uuid(_), do: nil

  defp event_store_destination_name(meta) do
    to_destination_name(meta[:event_store_name]) ||
      meta[:application]
      |> lookup_event_store_name()
      |> to_destination_name() ||
      Helpers.module_name(meta[:application])
  end

  defp lookup_event_store_name(nil), do: nil

  defp lookup_event_store_name(application) do
    {_adapter, adapter_meta} = CommandedApplication.event_store_adapter(application)

    Map.get(adapter_meta, :name) || Map.get(adapter_meta, :event_store)
  rescue
    ArgumentError -> nil
    RuntimeError -> nil
  end

  defp to_destination_name(nil), do: nil
  defp to_destination_name(name) when is_binary(name), do: name
  defp to_destination_name(name) when is_atom(name), do: inspect(name)
  defp to_destination_name(_), do: nil

  defp to_start_from_attr(nil), do: nil
  defp to_start_from_attr(atom) when is_atom(atom), do: to_string(atom)
  defp to_start_from_attr(other), do: other
end
