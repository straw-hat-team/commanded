defmodule Commanded.TestSupport.ModuleLoggerLevelHelpers do
  @moduledoc false

  import ExUnit.Callbacks

  require Logger

  def suppress_module_log_level(module, level) do
    previous_level = Logger.get_module_level(module)
    Logger.put_module_level(module, level)

    on_exit(fn ->
      restore_module_log_level(module, previous_level)
    end)

    :ok
  end

  defp restore_module_log_level(module, []), do: Logger.delete_module_level(module)

  defp restore_module_log_level(module, [{logged_module, level}])
       when logged_module == module do
    Logger.put_module_level(module, level)
  end
end
