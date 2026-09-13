defmodule AssertCommit.Assertions.Mix do
  @moduledoc """
  Assertions over `mix.exs` and `mix.lock`, built on `AssertCommit.MixFile`.
  """

  alias AssertCommit.Assertions.Flunk
  alias AssertCommit.{Commit, MixFile}

  @doc "Dependencies the commit adds to `mix.exs`."
  @spec deps_added(Commit.t()) :: [MixFile.dep()]
  def deps_added(%Commit{before: before, after: after_tree}) do
    old = MapSet.new(MixFile.all_deps(before), & &1.name)
    for dep <- MixFile.all_deps(after_tree), not MapSet.member?(old, dep.name), do: dep
  end

  @doc "Dependencies the commit removes from `mix.exs`."
  @spec deps_removed(Commit.t()) :: [MixFile.dep()]
  def deps_removed(%Commit{before: before, after: after_tree}) do
    new = MapSet.new(MixFile.all_deps(after_tree), & &1.name)
    for dep <- MixFile.all_deps(before), not MapSet.member?(new, dep.name), do: dep
  end

  @doc "The version the commit sets in `mix.exs`, if it changed it."
  @spec version_bump(Commit.t()) :: {String.t() | nil, String.t()} | nil
  def version_bump(%Commit{before: before, after: after_tree}) do
    old = MixFile.version(before)
    new = MixFile.version(after_tree)
    if new != nil and new != old, do: {old, new}
  end

  @doc """
  Asserts every hex dependency the commit adds to any `mix.exs` is present in
  a resulting `mix.lock`, and every one it removes is absent — the lockfile
  was regenerated with the change. Umbrella apps share the root lockfile.

  Path and git dependencies without a lock entry are not required to appear.
  """
  @spec assert_lock_in_sync(Commit.t()) :: :ok
  def assert_lock_in_sync(%Commit{after: after_tree} = commit) do
    locked = MapSet.new(MixFile.all_locked(after_tree))

    missing =
      for dep <- deps_added(commit),
          hex?(dep),
          not MapSet.member?(locked, dep.name),
          do: "#{inspect(dep.name)} was added to mix.exs but is not in mix.lock"

    stale =
      for dep <- deps_removed(commit),
          MapSet.member?(locked, dep.name),
          do: "#{inspect(dep.name)} was removed from mix.exs but is still in mix.lock"

    case missing ++ stale do
      [] ->
        :ok

      problems ->
        Flunk.flunk(
          ["mix.lock is out of sync with mix.exs:" | Flunk.indent(problems)] ++
            ["", "Run `mix deps.get` and commit the lockfile with the dependency change."]
        )
    end
  end

  defp hex?(%{opts: opts}),
    do:
      not (Keyword.has_key?(opts, :path) or Keyword.has_key?(opts, :git) or
             Keyword.has_key?(opts, :github))
end
