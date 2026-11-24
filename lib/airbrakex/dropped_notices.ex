defmodule Airbrakex.DroppedNotices do
  @moduledoc """
  Counts logger notices that were dropped instead of being sent to Airbrake.

  `Airbrakex.LoggerBackend` cannot log from inside the Logger process, so a
  counter is the only way to see that Airbrake is under-reporting during an
  error storm. Read it with `Airbrakex.dropped_notices/0`.
  """

  @key {__MODULE__, :counter}

  @doc """
  Creates the counter. Called once when the `:airbrakex` application starts.
  """
  @spec init() :: :ok
  def init do
    :persistent_term.put(@key, :counters.new(1, [:write_concurrency]))
  end

  @doc """
  Records one dropped notice. A no-op when the application is not running.
  """
  @spec increment() :: :ok
  def increment do
    @key
    |> :persistent_term.get(nil)
    |> add_one()
  end

  @doc """
  Number of notices dropped since the application started.
  """
  @spec count() :: non_neg_integer()
  def count do
    @key
    |> :persistent_term.get(nil)
    |> read()
  end

  defp add_one(nil), do: :ok
  defp add_one(counter), do: :counters.add(counter, 1, 1)

  defp read(nil), do: 0
  defp read(counter), do: :counters.get(counter, 1)
end
