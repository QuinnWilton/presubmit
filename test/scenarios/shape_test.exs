defmodule AssertCommit.Scenarios.ShapeTest do
  @moduledoc """
  The commit requirements — atomic, bisectable, separate concerns — run
  against `fixtures/shape`.
  """

  use ExUnit.Case, async: true

  import AssertCommit.Query
  import AssertCommit.RuleHelpers

  alias AssertCommit.{Fixtures, Rules}

  setup_all do: %{repo: Fixtures.repo("shape")}

  describe "Rules.Elixir :pure_move" do
    test "a move that only renames modules passes", %{repo: repo} do
      commit = scenario(repo, :pure_move)
      assert length(renamed(commit)) == 2
      assert length(modules_renamed(commit)) == 2
      refute behaviour_changed?(commit)
      assert_pass(run_rule(Rules.Elixir, :pure_move, commit))
    end

    test "a move with a behaviour change fails naming the function", %{repo: repo} do
      commit = scenario(repo, :move_with_edits)
      [{_, f}] = elixir_diff(commit).functions.body_changed
      assert_fail(run_rule(Rules.Elixir, :pure_move, commit), message)
      assert message =~ "renames files, so it must contain nothing else"
      assert message =~ "#{inspect(f.module)}.#{f.name}/#{f.arity} (added or changed)"
    end

    test "commits with no renames pass trivially", %{repo: repo} do
      assert_pass(run_rule(Rules.Elixir, :pure_move, scenario(repo, :lib_with_tests)))
    end
  end

  describe "formatting-only commits" do
    test "are detected", %{repo: repo} do
      commit = scenario(repo, :formatting_only)
      assert formatting_only?(commit)
      refute behaviour_changed?(commit)
    end

    test "are distinguished from a logic change hidden in a reformat", %{repo: repo} do
      commit = scenario(repo, :formatting_with_logic)
      refute formatting_only?(commit)
      assert behaviour_changed?(commit)
    end
  end

  describe "Rules.ExUnit :behaviour_changes_tested" do
    test "passes when tests change too", %{repo: repo} do
      commit = scenario(repo, :lib_with_tests)
      assert behaviour_changed?(commit)
      assert_pass(run_rule(Rules.ExUnit, :behaviour_changes_tested, commit))
    end

    test "fails naming the changed function", %{repo: repo} do
      commit = scenario(repo, :lib_without_tests)
      [{_, f}] = elixir_diff(commit).functions.body_changed
      assert_fail(run_rule(Rules.ExUnit, :behaviour_changes_tested, commit), message)

      assert message =~
               "Behaviour changed without any test changing:\n  #{inspect(f.module)}.#{f.name}/#{f.arity} (body changed)"
    end

    test "is vacuous for a docs-only change", %{repo: repo} do
      commit = scenario(repo, :docs_only)
      assert modified(commit, ~r{^lib/}) != []
      refute behaviour_changed?(commit)
      assert_pass(run_rule(Rules.ExUnit, :behaviour_changes_tested, commit))
    end

    test "is vacuous for a reformat", %{repo: repo} do
      assert_pass(
        run_rule(Rules.ExUnit, :behaviour_changes_tested, scenario(repo, :formatting_only))
      )
    end
  end

  describe "Rules.Shape" do
    test "pass under the ceilings", %{repo: repo} do
      commit = scenario(repo, :lib_with_tests)
      assert_pass(run_rule(Rules.Shape, :max_files, commit, max_files: 20))
      assert_pass(run_rule(Rules.Shape, :max_additions, commit, max_additions: 400))
    end

    test "fail over them", %{repo: repo} do
      commit = scenario(repo, :oversized)
      count = length(commit.changes)
      assert_fail(run_rule(Rules.Shape, :max_files, commit, max_files: 20), message)
      assert message =~ "at most 20 changed files, but the commit changes #{count}"
    end
  end

  describe "Rules.Hygiene :no_artifacts" do
    test "passes on source-only commits", %{repo: repo} do
      assert_pass(run_rule(Rules.Hygiene, :no_artifacts, scenario(repo, :lib_with_tests)))
    end

    test "fails listing every offender, binary ones included", %{repo: repo} do
      commit = scenario(repo, :artifacts_committed)
      assert Enum.any?(commit.changes, & &1.binary?)
      artifacts = [~r{^priv/static/assets/}, ~r/\.DS_Store$/, ~r/\.(orig|rej|beam)$/]
      assert_fail(run_rule(Rules.Hygiene, :no_artifacts, commit, artifacts: artifacts), message)
      for path <- added(commit), do: assert(message =~ path)
    end
  end
end
