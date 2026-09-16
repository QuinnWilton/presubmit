defmodule Presubmit.Concuerror.CacheRace do
  @moduledoc """
  Concuerror scenario for `Presubmit.Source.Cache`: two processes race to
  create and fill the table, one of them may own it and die, and a reader
  then fetches again. Every fetch must return the computed value.

  Run with `mix run --no-start test/concuerror/run.exs` in the test environment.
  """

  alias Presubmit.Source.Cache

  @doc false
  def run do
    parent = self()
    compute = fn -> {:facts, 1} end

    pids =
      for _ <- 1..2 do
        spawn_link(fn -> send(parent, {self(), Cache.fetch(:key, compute)}) end)
      end

    for pid <- pids do
      receive do
        {^pid, {:facts, 1}} -> :ok
      end
    end

    {:facts, 1} = Cache.fetch(:key, compute)
    :ok = Cache.clear()
    :miss = Cache.get(:key)
    :ok
  end
end
