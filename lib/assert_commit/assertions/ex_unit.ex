defmodule AssertCommit.Assertions.ExUnit do
  @moduledoc """
  Assertions over test coverage of a change, built on
  `AssertCommit.Adapters.ExUnitCase`.
  """

  alias AssertCommit.Adapters.ExUnitCase
  alias AssertCommit.Assertions.Flunk
  alias AssertCommit.{Commit, Query, Source}

  @doc """
  Asserts every module the commit adds under `lib/` has a test module in the
  resulting tree: one named `<Module>Test`, or one that references the module.
  """
  @spec assert_tested(Commit.t()) :: :ok
  def assert_tested(%Commit{} = commit) do
    added =
      for m <- Query.module_facts_added(commit), String.starts_with?(m.path, "lib/"), do: m.name

    case added do
      [] ->
        :ok

      _ ->
        cases = Source.find(commit.after, ExUnitCase, ~r{^test/})
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
    if Query.behaviour_changed?(commit) and not Query.touches?(commit, ~r{^test/}) do
      diff = Query.elixir_diff(commit)

      changed =
        Enum.map(diff.functions.added, &"#{inspect(&1.module)}.#{&1.name}/#{&1.arity} (added)") ++
          Enum.map(
            diff.functions.removed,
            &"#{inspect(&1.module)}.#{&1.name}/#{&1.arity} (removed)"
          ) ++
          Enum.map(diff.functions.body_changed, fn {_, f} ->
            "#{inspect(f.module)}.#{f.name}/#{f.arity} (body changed)"
          end)

      Flunk.flunk(["Behaviour changed without any test changing:" | Flunk.indent(changed)])
    else
      :ok
    end
  end
end
