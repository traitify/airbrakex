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

  alias Airbrakex.{DroppedNotices, LoggerParser, Notifier}

  # Tighter than the Notifier defaults: a notice task holds one of a small
  # number of slots. `config :airbrakex, :http_options` still overrides these.
  @http_options [timeout: 1_000, recv_timeout: 1_000]
  # Covers one notice at the 1s connect + 1s receive timeouts above.
  @flush_timeout_ms 2_000
  @default_notice_deadline_ms 5_000

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

  # With `drain_on_flush: true`, an explicit `Logger.flush/0` lets in-flight
  # notices finish (bounded). Opt-in because a flush blocks every Logger
  # backend while it waits, and `ExUnit.CaptureLog` flushes after each capture.
  def handle_event(:flush, state) do
    drain_on_flush(Application.get_env(:airbrakex, :drain_on_flush, false))
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

    Airbrakex.TaskSupervisor
    |> Task.Supervisor.start_child(fn -> notify(msg, params) end)
    |> count_drop()
  catch
    :exit, _reason -> DroppedNotices.increment()
  end

  defp count_drop({:ok, _pid}), do: :ok
  defp count_drop({:error, _reason}), do: DroppedNotices.increment()

  # Runs in the task. Nothing may escape it: a crash here would be logged as an
  # error and come straight back to this backend as another notice.
  defp notify(msg, params) do
    Logger.metadata(airbrakex: false)
    start_deadline()

    msg
    |> IO.chardata_to_string()
    |> LoggerParser.parse()
    |> Notifier.notify(params: params, http_options: @http_options)
  catch
    # Catches raised exceptions (kind `:error`) as well as exits and throws.
    _kind, _reason -> :error
  end

  # The HTTP timeouts only bound gaps between packets, so a trickling Airbrake
  # could hold a slot indefinitely. The `{:shutdown, _}` reason matters: the
  # task supervisor reports any other abnormal exit at `:error` level, which
  # this backend would pick up as a new notice.
  defp start_deadline do
    :timer.exit_after(notice_deadline(), self(), {:shutdown, :airbrakex_deadline})
  end

  @doc false
  # `:timer.exit_after/3` returns `{:error, :badarg}` for a bad time instead of
  # raising, so an invalid `notice_deadline` would silently turn the deadline off.
  @spec notice_deadline() :: pos_integer()
  def notice_deadline do
    :airbrakex
    |> Application.get_env(:notice_deadline)
    |> validate_notice_deadline()
  end

  defp validate_notice_deadline(ms) when is_integer(ms) and ms > 0, do: ms
  defp validate_notice_deadline(_invalid), do: @default_notice_deadline_ms

  defp drain_on_flush(true), do: Airbrakex.Application.drain_notices(@flush_timeout_ms)
  defp drain_on_flush(_disabled), do: :ok

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
