defmodule Airbrakex.NoticeDrain do
  @moduledoc """
  Gives in-flight logger notices a moment to finish when `:airbrakex` shuts down.

  Errors logged just before shutdown (boot failures, crash loops) are the ones
  most worth reporting. This process does nothing while running; on shutdown it
  waits for `Airbrakex.TaskSupervisor` to empty before that supervisor is
  stopped. It lives in the supervision tree rather than in
  `c:Application.prep_stop/1` because `prep_stop` is not called when the whole
  VM stops, which is how a service exits on SIGTERM.
  """

  use GenServer

  # Covers one notice at the default 1s connect + 1s receive timeouts.
  @drain_timeout_ms 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: @drain_timeout_ms + 1_000
    }
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    Airbrakex.Application.drain_notices(@drain_timeout_ms)
  end
end
