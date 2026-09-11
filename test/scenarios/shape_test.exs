defmodule AssertCommit.Scenarios.ShapeTest do
  @moduledoc """
  The commit requirements — atomic, bisectable, separate concerns — as
  assertions on commit shape, run against `fixtures/shape`.
  """

  use ExUnit.Case, async: true
  use AssertCommit, repo: & &1.repo, rev: &"scenario/#{&1.scenario}"

  setup_all do: %{repo: AssertCommit.Fixtures.repo("shape")}

  describe "assert_pure_move/1" do
    @tag scenario: :pure_move
    test "a move that only renames modules passes", %{commit: commit} do
      assert length(renamed(commit)) == 2
      assert length(modules_renamed(commit)) == 2
      refute behaviour_changed?(commit)
      assert_pure_move(commit)
    end

    @tag scenario: :move_with_edits
    test "a move with a behaviour change fails naming the function", %{commit: commit} do
      [{_, f}] = elixir_diff(commit).functions.body_changed

      error = assert_raise ExUnit.AssertionError, fn -> assert_pure_move(commit) end
      assert error.message =~ "renames files, so it must contain nothing else"

      assert error.message =~
               "#{inspect(f.module)}.#{f.name}/#{f.arity} (body changed, line #{f.line})"
    end

    @tag scenario: :lib_with_tests
    test "commits with no renames pass trivially", %{commit: commit} do
      assert_pure_move(commit)
    end
  end

  describe "formatting-only commits" do
    @tag scenario: :formatting_only
    test "are detected", %{commit: commit} do
      assert formatting_only?(commit)
      refute behaviour_changed?(commit)
    end

    @tag scenario: :formatting_with_logic
    test "are distinguished from a logic change hidden in a reformat", %{commit: commit} do
      refute formatting_only?(commit)
      assert behaviour_changed?(commit)
    end
  end

  describe "assert_behaviour_changes_tested/1" do
    @tag scenario: :lib_with_tests
    test "passes when tests change too", %{commit: commit} do
      assert behaviour_changed?(commit)
      assert_behaviour_changes_tested(commit)
    end

    @tag scenario: :lib_without_tests
    test "fails naming the changed function", %{commit: commit} do
      [{_, f}] = elixir_diff(commit).functions.body_changed

      error =
        assert_raise ExUnit.AssertionError, fn -> assert_behaviour_changes_tested(commit) end

      assert error.message =~
               "Behaviour changed without any test changing:\n  #{inspect(f.module)}.#{f.name}/#{f.arity} (body changed)"
    end

    @tag scenario: :docs_only
    test "is vacuous for a docs-only change", %{commit: commit} do
      assert modified(commit, ~r{^lib/}) != []
      refute behaviour_changed?(commit)
      assert_behaviour_changes_tested(commit)
    end

    @tag scenario: :formatting_only
    test "is vacuous for a reformat", %{commit: commit} do
      assert_behaviour_changes_tested(commit)
    end
  end

  describe "size ceilings" do
    @tag scenario: :lib_with_tests
    test "pass under the ceiling", %{commit: commit} do
      assert_max_files(commit, 20)
      assert_max_additions(commit, 400)
    end

    @tag scenario: :oversized
    test "fail over it", %{commit: commit} do
      count = length(commit.changes)

      assert_raise ExUnit.AssertionError,
                   ~r/at most 20 changed files, but the commit changes #{count}/,
                   fn -> assert_max_files(commit, 20) end
    end
  end

  describe "refute_added/2: generated artifacts and editor droppings" do
    @forbidden [~r{^priv/static/assets/}, ~r/\.DS_Store$/, ~r/\.(orig|rej|beam)$/]

    @tag scenario: :lib_with_tests
    test "passes on source-only commits", %{commit: commit} do
      refute_added(commit, @forbidden)
    end

    @tag scenario: :artifacts_committed
    test "fails listing every offender, binary ones included", %{commit: commit} do
      assert Enum.any?(commit.changes, & &1.binary?)

      error = assert_raise ExUnit.AssertionError, fn -> refute_added(commit, @forbidden) end
      for path <- added(commit), do: assert(error.message =~ path)
    end
  end
end
