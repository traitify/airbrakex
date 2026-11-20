defmodule Airbrakex.LoggerBackend do
  @moduledoc """
  A Logger backend to send exceptions from logs to the `airbrake`

  ## Usage

  ```elixir
  config :logger,
    backends: [Airbrakex.LoggerBackend]
  ```
  """

  @behaviour :gen_event

  alias Airbrakex.{LoggerParser, Notifier}

  def init(__MODULE__) do
    {:ok, configure([])}
  end

  def handle_call({:configure, opts}, _state) do
    {:ok, :ok, configure(opts)}
  end

  def handle_event({_level, gl, _event}, state) when node(gl) != node() do
    {:ok, state}
  end

  def handle_event({level, _gl, event}, %{metadata: keys} = state) do
    if proceed?(event) and meet_level?(level, state.level) do
      post_event(event, keys)
    end

    {:ok, state}
  end

  def handle_event(:flush, state) do
    {:ok, state}
  end

  def handle_info(_message, state) do
    {:ok, state}
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(_reason, _state) do
    :ok
  end

  defp proceed?({Logger, _msg, _ts, meta} = log) do
    Keyword.get(meta, :airbrakex, true) and
      not ignore_backend?(Application.get_env(:airbrakex, :ignore_backend), log)
  end

  defp ignore_backend?(ignore, _error) when is_nil(ignore), do: false
  defp ignore_backend?({module, function, []}, log), do: apply(module, function, [log])
  defp ignore_backend?(ignore, log) when is_function(ignore), do: ignore.(log)

  defp meet_level?(lvl, min) do
    Logger.compare_levels(normalize_level(lvl), normalize_level(min)) != :lt
  end

  defp normalize_level(:warn) do
    :warning
  end

  defp normalize_level(any) do
    any
  end

  # Logger must never wait on Airbrake: the notice is built and sent in a
  # supervised task. When the supervisor is at `max_children` (or is not
  # running) the notice is dropped rather than queued.
  defp post_event({Logger, msg, _ts, meta}, keys) do
    # Filtered here so the task is only sent the metadata it will report.
    params = take_into_map(meta, keys)

    Task.Supervisor.start_child(Airbrakex.TaskSupervisor, fn -> notify(msg, params) end)
  catch
    :exit, _reason -> :dropped
  end

  # Runs in the task. Nothing may escape it: a crash here would be logged as an
  # error and come straight back to this backend as another notice.
  defp notify(msg, params) do
    Logger.metadata(airbrakex: false)

    msg
    |> IO.chardata_to_string()
    |> LoggerParser.parse()
    |> Notifier.notify(params: params)
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp take_into_map(metadata, keys) do
    Enum.reduce(metadata, %{}, fn {key, val}, acc ->
      if key in keys, do: Map.put(acc, key, val), else: acc
    end)
  end

  defp configure(opts) do
    config =
      :logger
      |> Application.get_env(__MODULE__, [])
      |> Keyword.merge(opts)

    Application.put_env(:logger, __MODULE__, config)

    %{
      level: Application.get_env(:airbrakex, :logger_level, :error),
      metadata: Keyword.get(config, :metadata, [])
    }
  end
end
