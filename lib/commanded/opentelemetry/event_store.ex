defmodule Commanded.OpenTelemetry.EventStore do
  @moduledoc false

  alias Commanded.Application, as: CommandedApplication
  alias Commanded.OpenTelemetry.CommandedAttributes
  alias Commanded.OpenTelemetry.Helpers
  alias Commanded.OpenTelemetry.SemConv
  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.DBAttributes
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes
  alias OpenTelemetry.SemConv.ServerAttributes
  alias OpenTelemetry.Span

  @tracer_id __MODULE__

  @events ~w(
    append_to_stream
    delete_snapshot
    read_snapshot
    record_snapshot
    stream_forward
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
    action_name = to_string(action)
    {adapter, adapter_meta} = fetch_event_store_adapter(meta[:application])
    event_store_name = event_store_name(adapter_meta)
    destination_name = Helpers.to_destination_name(event_store_name)
    source_uuid = extract_source_uuid(meta)
    connection_config = lookup_connection_config(adapter, event_store_name)
    db_namespace = database_namespace(connection_config, destination_name)
    span_target = span_target(connection_config, db_namespace, destination_name)

    attributes =
      [
        legacy_database_attrs(action, action_name, destination_name, adapter),
        stable_database_attrs(action_name, connection_config, db_namespace, adapter),
        {SemConv.code_function_name_key(), SemConv.event_store_code_function_name(action)},
        {CommandedAttributes.commanded_application(), Helpers.module_name(meta[:application])}
      ]
      |> List.flatten()
      |> Helpers.compact_attrs()
      |> Helpers.maybe_add_stream_uuid(meta[:stream_uuid])
      |> Helpers.maybe_add_expected_version(meta[:expected_version])
      |> Helpers.maybe_add_event_count(meta[:event_count])
      |> Helpers.maybe_add_source_uuid(source_uuid)
      |> maybe_add_start_from(meta[:start_from])
      |> maybe_add_start_version(meta[:start_version])
      |> maybe_add_read_batch_size(meta[:read_batch_size])
      |> maybe_add_connection_attrs(connection_config)

    span_name = span_name(action_name, span_target)

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      span_name,
      meta,
      %{
        kind: :client,
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

  defp legacy_database_attrs(action, action_name, destination_name, adapter) do
    identifiers = SemConv.database_system_identifiers(adapter)

    if SemConv.legacy_database?() do
      [
        {MessagingAttributes.messaging_system(), "commanded"},
        {MessagingAttributes.messaging_operation_name(), action_name},
        maybe_legacy_operation_type(action),
        Helpers.maybe_attr(MessagingAttributes.messaging_destination_name(), destination_name),
        Helpers.maybe_attr(
          OpenTelemetry.SemConv.Incubating.DBAttributes.db_system(),
          identifiers.legacy
        )
      ]
    else
      []
    end
  end

  defp stable_database_attrs(action_name, _connection_config, db_namespace, adapter) do
    identifiers = SemConv.database_system_identifiers(adapter)

    if SemConv.stable_database?() do
      [
        Helpers.maybe_attr(SemConv.db_system_name_key(), identifiers.stable),
        {DBAttributes.db_operation_name(), action_name},
        Helpers.maybe_attr(DBAttributes.db_namespace(), db_namespace)
      ]
    else
      []
    end
  end

  defp maybe_add_connection_attrs(attrs, [_ | _] = connection_config) do
    attrs
    |> Helpers.maybe_add_attr(ServerAttributes.server_address(), connection_config[:hostname])
    |> Helpers.maybe_add_attr(ServerAttributes.server_port(), connection_config[:port])
    |> maybe_add_peer_service(connection_config)
  end

  defp maybe_add_connection_attrs(attrs, _connection_config), do: attrs

  defp maybe_add_peer_service(attrs, connection_config) do
    if SemConv.legacy_database?() do
      Helpers.maybe_add_attr(
        attrs,
        OpenTelemetry.SemConv.Incubating.PeerAttributes.peer_service(),
        connection_config[:database]
      )
    else
      attrs
    end
  end

  defp maybe_legacy_operation_type(:append_to_stream) do
    {MessagingAttributes.messaging_operation_type(),
     SemConv.legacy_messaging_operation_type(:send)}
  end

  defp maybe_legacy_operation_type(:record_snapshot) do
    {MessagingAttributes.messaging_operation_type(),
     SemConv.legacy_messaging_operation_type(:send)}
  end

  defp maybe_legacy_operation_type(:stream_forward) do
    {MessagingAttributes.messaging_operation_type(),
     SemConv.legacy_messaging_operation_type(:receive)}
  end

  defp maybe_legacy_operation_type(:read_snapshot) do
    {MessagingAttributes.messaging_operation_type(),
     SemConv.legacy_messaging_operation_type(:receive)}
  end

  defp maybe_legacy_operation_type(_), do: nil

  defp maybe_add_start_from(attrs, nil), do: attrs

  defp maybe_add_start_from(attrs, start_from),
    do: [{CommandedAttributes.commanded_start_from(), to_start_from_attr(start_from)} | attrs]

  defp maybe_add_start_version(attrs, nil), do: attrs

  defp maybe_add_start_version(attrs, version),
    do: [{CommandedAttributes.commanded_stream_start_version(), version} | attrs]

  defp maybe_add_read_batch_size(attrs, nil), do: attrs

  defp maybe_add_read_batch_size(attrs, size),
    do: [{CommandedAttributes.commanded_stream_batch_size(), size} | attrs]

  # Extract source_uuid from metadata or nested snapshot struct (record_snapshot operation)
  defp extract_source_uuid(%{source_uuid: uuid}) when is_binary(uuid), do: uuid
  defp extract_source_uuid(%{snapshot: %{source_uuid: uuid}}) when is_binary(uuid), do: uuid
  defp extract_source_uuid(_), do: nil

  defp database_namespace([_ | _] = connection_config, destination_name) do
    connection_config[:database] || destination_name
  end

  defp database_namespace(_connection_config, _destination_name), do: nil

  defp span_target([_ | _] = connection_config, db_namespace, destination_name) do
    cond do
      db_namespace ->
        db_namespace

      connection_config[:hostname] && connection_config[:port] ->
        "#{connection_config[:hostname]}:#{connection_config[:port]}"

      true ->
        destination_name
    end
  end

  defp span_target(_connection_config, db_namespace, destination_name) do
    db_namespace || destination_name
  end

  defp span_name(action_name, nil), do: action_name
  defp span_name(action_name, target), do: "#{action_name} #{target}"

  defp lookup_connection_config(Commanded.EventStore.Adapters.EventStore, event_store_name)
       when is_atom(event_store_name) and not is_nil(event_store_name) do
    EventStore.Config.lookup(event_store_name)
  rescue
    _ -> []
  end

  defp lookup_connection_config(_adapter, _event_store_name), do: []

  defp fetch_event_store_adapter(application) do
    {_adapter, _adapter_meta} = CommandedApplication.event_store_adapter(application)
  rescue
    error ->
      :telemetry.execute(
        [:commanded, :opentelemetry, :warning],
        %{count: 1},
        %{
          message:
            "Failed to resolve event store adapter metadata, leaving event store destination unset",
          application: application,
          error: error,
          tracer_id: @tracer_id
        }
      )

      {nil, nil}
  end

  defp event_store_name(adapter_meta) when is_map(adapter_meta),
    do: Map.get(adapter_meta, :name) || Map.get(adapter_meta, :event_store)

  defp event_store_name(_), do: nil

  defp to_start_from_attr(nil), do: nil
  defp to_start_from_attr(atom) when is_atom(atom), do: to_string(atom)
  defp to_start_from_attr(other), do: other
end
