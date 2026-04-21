defmodule Commanded.OpenTelemetry.SemConv do
  @moduledoc false

  @type mode :: :old | :new | :dup
  @type exception_signal_mode :: :span_events | :logs | :dup

  @spec messaging_mode() :: mode()
  def messaging_mode, do: stability_mode("messaging")

  @spec database_mode() :: mode()
  def database_mode, do: stability_mode("database")

  @spec exception_signal_mode() :: exception_signal_mode()
  def exception_signal_mode do
    values = env_values("OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN")

    cond do
      "logs/dup" in values -> :dup
      "logs" in values -> :logs
      true -> :span_events
    end
  end

  @spec legacy_messaging?() :: boolean()
  def legacy_messaging?, do: messaging_mode() in [:old, :dup]

  @spec stable_messaging?() :: boolean()
  def stable_messaging?, do: messaging_mode() in [:new, :dup]

  @spec legacy_database?() :: boolean()
  def legacy_database?, do: database_mode() in [:old, :dup]

  @spec stable_database?() :: boolean()
  def stable_database?, do: database_mode() in [:new, :dup]

  @spec code_function_name_key() :: :"code.function.name"
  def code_function_name_key, do: :"code.function.name"

  @spec db_system_name_key() :: :"db.system.name"
  def db_system_name_key, do: :"db.system.name"

  @spec code_function_name(atom() | String.t() | nil, atom() | String.t() | nil) ::
          String.t() | nil
  def code_function_name(nil, nil), do: nil

  def code_function_name(nil, function_name) do
    to_function_name(function_name)
  end

  def code_function_name(module_name, nil) when is_binary(module_name), do: module_name
  def code_function_name(module_name, nil) when is_atom(module_name), do: inspect(module_name)

  def code_function_name(module_name, function_name) when is_atom(module_name) do
    "#{inspect(module_name)}.#{to_function_name(function_name)}"
  end

  def code_function_name(module_name, function_name) when is_binary(module_name) do
    "#{module_name}.#{to_function_name(function_name)}"
  end

  @spec event_store_code_function_name(atom()) :: String.t()
  def event_store_code_function_name(action) when is_atom(action) do
    code_function_name(Commanded.EventStore, action)
  end

  @spec legacy_messaging_operation_type(:send | :create | :receive | :process | :settle) ::
          atom()
  def legacy_messaging_operation_type(:send), do: :publish
  def legacy_messaging_operation_type(:create), do: :create
  def legacy_messaging_operation_type(:receive), do: :receive
  def legacy_messaging_operation_type(:process), do: :process
  def legacy_messaging_operation_type(:settle), do: :settle

  @spec stable_messaging_operation_type(:send | :create | :receive | :process | :settle) ::
          String.t()
  def stable_messaging_operation_type(:send), do: "send"
  def stable_messaging_operation_type(:create), do: "create"
  def stable_messaging_operation_type(:receive), do: "receive"
  def stable_messaging_operation_type(:process), do: "process"
  def stable_messaging_operation_type(:settle), do: "settle"

  @spec database_system_identifiers(module() | nil) :: %{
          legacy: atom() | nil,
          stable: String.t() | nil
        }
  def database_system_identifiers(Commanded.EventStore.Adapters.EventStore) do
    %{legacy: :postgresql, stable: "postgresql"}
  end

  def database_system_identifiers(Commanded.EventStore.Adapters.InMemory) do
    %{legacy: :in_memory, stable: "in_memory"}
  end

  def database_system_identifiers(_), do: %{legacy: nil, stable: nil}

  @spec supports_exception_signal_opt_in?() :: boolean()
  def supports_exception_signal_opt_in?, do: false

  @spec unsupported_exception_signal_opt_in?() :: boolean()
  def unsupported_exception_signal_opt_in? do
    exception_signal_mode() != :span_events and not supports_exception_signal_opt_in?()
  end

  defp stability_mode(category) do
    values = env_values("OTEL_SEMCONV_STABILITY_OPT_IN")

    cond do
      "#{category}/dup" in values -> :dup
      category in values -> :new
      true -> :old
    end
  end

  defp env_values(name) do
    name
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp to_function_name(function_name) when is_atom(function_name),
    do: Atom.to_string(function_name)

  defp to_function_name(function_name) when is_binary(function_name), do: function_name
  defp to_function_name(_), do: nil
end
