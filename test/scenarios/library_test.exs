defmodule AssertCommit.Scenarios.LibraryTest do
  @moduledoc """
  Process rules for a published hex package, run against `fixtures/library`.
  """

  use ExUnit.Case, async: true
  use AssertCommit, repo: & &1.repo, rev: &"scenario/#{&1.scenario}"

  setup_all do: %{repo: AssertCommit.Fixtures.repo("library")}

  describe "assert_api_changes_logged/1" do
    @tag scenario: :api_added_with_changelog
    test "passes when the unreleased section grew", %{commit: commit} do
      assert %{added: [_], removed: []} = public_api_diff(commit)
      assert_api_changes_logged(commit)
    end

    @tag scenario: :api_added_without_changelog
    test "fails naming the API change", %{commit: commit} do
      [{m, f, a}] = public_api_diff(commit).added

      error = assert_raise ExUnit.AssertionError, fn -> assert_api_changes_logged(commit) end
      assert error.message =~ "the unreleased section of CHANGELOG.md did not"
      assert error.message =~ "#{inspect(m)}.#{f}/#{a} added"
    end

    @tag scenario: :deps_changed_with_lock
    test "is vacuous when the public API is unchanged", %{commit: commit} do
      refute public_api_changed?(commit)
      assert_api_changes_logged(commit)
    end
  end

  describe "assert_specs/1" do
    @tag scenario: :api_added_with_changelog
    test("passes", %{commit: commit}, do: assert_specs(commit))

    @tag scenario: :api_added_without_spec
    test "fails naming the function", %{commit: commit} do
      [{m, f, a}] = public_api_diff(commit).added

      error = assert_raise ExUnit.AssertionError, fn -> assert_specs(commit) end
      assert error.message =~ "have no @spec:\n  #{inspect(m)}.#{f}/#{a}"
    end
  end

  describe "removing a public function" do
    @tag scenario: :function_removed_with_breaking_trailer
    test "assert_trailer/3 passes with a BREAKING CHANGE naming the function", %{commit: commit} do
      [{_m, f, a}] = public_api_diff(commit).removed
      assert_trailer(commit, "BREAKING CHANGE", ~r/#{f}\/#{a}/)
    end

    @tag scenario: :function_removed_without_breaking_trailer
    test "assert_trailer/2 fails without the trailer", %{commit: commit} do
      assert public_api_diff(commit).removed != []

      error =
        assert_raise ExUnit.AssertionError, fn -> assert_trailer(commit, "BREAKING CHANGE") end

      assert error.message =~
               "Expected a `BREAKING CHANGE:` trailer, but the message has no trailers."
    end

    @tag scenario: :function_removed_with_breaking_trailer
    test "assert_removals_deprecated/1 fails because it was never deprecated", %{commit: commit} do
      [{m, f, a}] = public_api_diff(commit).removed

      error = assert_raise ExUnit.AssertionError, fn -> assert_removals_deprecated(commit) end
      assert error.message =~ "removed without a prior @deprecated:\n  #{inspect(m)}.#{f}/#{a}"
    end

    @tag scenario: :api_added_with_changelog
    test "assert_removals_deprecated/1 is vacuous when nothing was removed", %{commit: commit} do
      assert_removals_deprecated(commit)
    end
  end

  describe "new modules" do
    @tag scenario: :new_module_with_test
    test "assert_tested/1 and assert_moduledoc/1 pass", %{commit: commit} do
      assert_tested(commit)
      assert_moduledoc(commit)
    end

    @tag scenario: :new_module_without_test
    test "assert_tested/1 fails", %{commit: commit} do
      [added] = modules_added(commit, ~r{^lib/})
      error = assert_raise ExUnit.AssertionError, fn -> assert_tested(commit) end
      assert error.message =~ "have no test module"
      assert error.message =~ inspect(added)
    end

    @tag scenario: :new_module_without_moduledoc
    test "assert_moduledoc/1 fails", %{commit: commit} do
      [added] = modules_added(commit, ~r{^lib/})
      error = assert_raise ExUnit.AssertionError, fn -> assert_moduledoc(commit) end
      assert error.message =~ "have no @moduledoc:\n  #{inspect(added)}"
    end
  end

  describe "assert_lock_in_sync/1" do
    @tag scenario: :deps_changed_with_lock
    test "passes when the lockfile gained the dependency", %{commit: commit} do
      assert [%{name: name}] = deps_added(commit)
      assert name in AssertCommit.MixFile.locked(commit.after)
      assert_lock_in_sync(commit)
    end

    @tag scenario: :deps_changed_without_lock
    test "fails naming the missing lock entry", %{commit: commit} do
      [%{name: name}] = deps_added(commit)

      error = assert_raise ExUnit.AssertionError, fn -> assert_lock_in_sync(commit) end
      assert error.message =~ "#{inspect(name)} was added to mix.exs but is not in mix.lock"
      assert error.message =~ "Run `mix deps.get`"
    end

    @tag scenario: :api_added_with_changelog
    test "is vacuous when deps are unchanged", %{commit: commit} do
      assert deps_added(commit) == []
      assert_lock_in_sync(commit)
    end
  end

  describe "release commits" do
    # A version bump may touch only release metadata.
    defp assert_release_only(commit) do
      if version_bump(commit), do: refute_touched(commit, ~r{^(lib|test)/})
    end

    @tag scenario: :release_commit
    test "assert_release_logged/1 passes for a clean release", %{commit: commit} do
      assert {_, new} = version_bump(commit)
      assert AssertCommit.Changelog.section_for(commit.after, new)
      assert_release_logged(commit)
      assert_release_only(commit)
    end

    @tag scenario: :release_commit_with_code
    test "code riding along fails the release-only rule", %{commit: commit} do
      error = assert_raise ExUnit.AssertionError, fn -> assert_release_only(commit) end
      assert error.message =~ "but it touches:\n  lib/"
    end

    @tag scenario: :version_bump_without_changelog_heading
    test "assert_release_logged/1 fails without a section for the version", %{commit: commit} do
      {_, new} = version_bump(commit)
      error = assert_raise ExUnit.AssertionError, fn -> assert_release_logged(commit) end
      assert error.message =~ "has no `## #{new}` section"
    end

    @tag scenario: :api_added_with_changelog
    test "both are vacuous for non-release commits", %{commit: commit} do
      assert version_bump(commit) == nil
      assert_release_logged(commit)
      assert_release_only(commit)
    end
  end
end
