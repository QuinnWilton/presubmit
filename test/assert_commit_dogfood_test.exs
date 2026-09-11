defmodule AssertCommitDogfoodTest do
  @moduledoc """
  assert_commit's own commit policy, asserted on this repository's `HEAD`.

  Excluded automatically when `HEAD~1` is not available (fresh checkout or
  depth-1 clone); see `test/test_helper.exs`.
  """

  use ExUnit.Case, async: true
  use AssertCommit

  @moduletag :dogfood

  test "no debugging calls are committed", %{commit: commit} do
    refute_added_lines(commit, ~r/\b(IO\.inspect|dbg|IEx\.pry)\(/, in: ~r{^lib/})
  end

  test "no build artifacts or editor droppings", %{commit: commit} do
    refute_added(commit, [~r{^_build/}, ~r/\.beam$/, ~r/\.DS_Store$/, ~r/\.(orig|rej)$/])
  end

  test "new public functions have specs and new modules have docs", %{commit: commit} do
    assert_specs(commit)
    assert_moduledoc(commit)
  end

  test "moves are their own commit", %{commit: commit} do
    assert_pure_move(commit)
  end

  test "behaviour changes in lib/ ship with test changes", %{commit: commit} do
    assert_behaviour_changes_tested(commit)
  end

  # `assert_tested/1` is not applied here: the assertion modules are covered by the scenario
  # suites through `use AssertCommit`, which `ExUnitCase.covers?/2` cannot see as a reference.

  test "public API changes are logged and removals were deprecated first", %{commit: commit} do
    assert_api_changes_logged(commit)
    assert_removals_deprecated(commit)
  end

  test "mix.lock is in sync with mix.exs", %{commit: commit} do
    assert_lock_in_sync(commit)
  end

  test "releases have a changelog section", %{commit: commit} do
    assert_release_logged(commit)
  end

  test "LLM-assisted commits link their session", %{commit: commit} do
    if Enum.any?(trailer(commit, "Co-Authored-By"), &(&1 =~ ~r/anthropic\.com/)) do
      assert_trailer(commit, "Claude-Session", ~r{^https://claude\.ai/code/session_})
    end
  end

  test "subjects follow the [component] convention and fit in 72 columns", %{commit: commit} do
    assert_subject(commit, ~r/^\[[a-z_-]+\] .{1,60}$/)
    refute_subject(commit, ~r/^(fixup|squash|amend)!/)
  end
end
