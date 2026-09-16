defmodule Presubmit.Source.Cache do
  @moduledoc """
  The shared cache of extracted facts: a public ETS table keyed by
  `{blob_oid, path}`, so a range of commits parses each distinct file
  version once.

  The table is created by whichever process needs it first and dies with
  that process; the next user recreates it. Every operation tolerates the
  table vanishing between a lookup and an insert, so the worst case is a
  miss. The table is bounded: it is emptied when it grows past the limit.
  """

  @table :presubmit_facts
  @limit 50_000

  @doc "The cached value for `key`, computing and caching it with `compute` on a miss."
  @spec fetch(term(), (-> value)) :: value when value: term()
  def fetch(key, compute) when is_function(compute, 0) do
    case get(key) do
      {:ok, value} ->
        value

      :miss ->
        value = compute.()
        put(key, value)
        value
    end
  end

  @doc "The cached value for `key`, or `:miss`."
  @spec get(term()) :: {:ok, term()} | :miss
  def get(key) do
    case :ets.whereis(@table) do
      :undefined ->
        :miss

      tid ->
        case :ets.lookup(tid, key) do
          [{^key, value}] -> {:ok, value}
          [] -> :miss
        end
    end
  rescue
    # The owner died between `whereis` and `lookup`.
    ArgumentError -> :miss
  end

  @doc "Caches `value` under `key`."
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    tid =
      case :ets.whereis(@table) do
        :undefined -> create()
        tid -> tid
      end

    if :ets.info(tid, :size) > @limit, do: :ets.delete_all_objects(tid)
    :ets.insert(tid, {key, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops every cached value."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp create do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  rescue
    # Another process created it first.
    ArgumentError -> :ets.whereis(@table)
  end
end
