defmodule AssertCommit.Assertions.ExUnit do
  @moduledoc """
  Assertions over test coverage of a change, built on
  `AssertCommit.Adapters.ExUnitCase`.
  """

  alias AssertCommit.Adapters.ExUnitCase
  alias AssertCommit.Assertions.Flunk
  alias AssertCommit.{Commit, Paths, Query, Source}

  @doc """
  Asserts every module the commit adds under `lib/` has a test module in the
  resulting tree: one named `<Module>Test`, or one that references the module.
  """
  @spec assert_tested(Commit.t()) :: :ok
  def assert_tested(%Commit{} = commit) do
    added =
      for m <- Query.module_facts_added(commit), Regex.match?(Paths.lib(), m.path), do: m.name

    case added do
      [] ->
        :ok

      _ ->
        cases = Source.find(commit.after, ExUnitCase, Paths.test())
        untested = for m <- added, not Enum.any?(cases, &ExUnitCase.covers?(&1, m)), do: m

        case untested do
          [] ->
            :ok

          _ ->
            Flunk.flunk([
              "These added modules have no test module (`<Module>Test`, or any test referencing them):"
              | Flunk.indent(Enum.map(untested, &inspect/1))
            ])
        end
    end
  end

  @doc """
  Asserts that when the commit changes behaviour in `lib/` (function bodies,
  additions, removals — not docs or formatting), it also changes a test.
  """
  @spec assert_behaviour_changes_tested(Commit.t()) :: :ok
  def assert_behaviour_changes_tested(%Commit{} = commit) do
    if Query.behaviour_changed?(commit, Paths.lib()) and not Query.touches?(commit, Paths.test()) do
      %{added: added, removed: removed, body_changed: body_changed} =
        Query.function_changes(commit, Paths.lib())

      changed =
        Enum.map(added, &"#{inspect(&1.module)}.#{&1.name}/#{&1.arity} (added)") ++
          Enum.map(removed, &"#{inspect(&1.module)}.#{&1.name}/#{&1.arity} (removed)") ++
          Enum.map(body_changed, fn {_, f} ->
            "#{inspect(f.module)}.#{f.name}/#{f.arity} (body changed)"
          end)

      Flunk.flunk(["Behaviour changed without any test changing:" | Flunk.indent(changed)])
    else
      :ok
    end
  end
end
