defmodule Airbrakex.Application do
  @moduledoc """
  Starts the supervisor that sends `Airbrakex.LoggerBackend` notices off the
  Logger process.

  The number of notices in flight is capped by `:max_concurrent_notices`
  (default 10, read once at application start). Notices arriving while the cap
  is reached are dropped, so a slow or unreachable Airbrake can never build up
  a backlog.

  The default is deliberately small: notices use hackney's shared default
  connection pool, and a hung Airbrake must not be able to occupy most of it.
  """

  use Application

  @default_max_concurrent_notices 10

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Airbrakex.TaskSupervisor, max_children: max_concurrent_notices()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Airbrakex.Supervisor)
  end

  @doc """
  Maximum number of logger notices sent to Airbrake concurrently.

  Anything other than a positive integer falls back to the default, so a bad
  value can never stop the error reporter (and the service using it) from booting.
  """
  @spec max_concurrent_notices() :: pos_integer()
  def max_concurrent_notices do
    :airbrakex
    |> Application.get_env(:max_concurrent_notices)
    |> validate_max_concurrent_notices()
  end

  defp validate_max_concurrent_notices(max) when is_integer(max) and max > 0, do: max
  defp validate_max_concurrent_notices(_invalid), do: @default_max_concurrent_notices
end
