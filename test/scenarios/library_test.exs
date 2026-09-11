defmodule AssertCommit.Scenarios.LibraryTest do
  @moduledoc """
  The Elixir, Changelog, Mix, and ExUnit rule sets run against
  `fixtures/library`, a published hex package.
  """

  use ExUnit.Case, async: true

  import AssertCommit.Query
  import AssertCommit.RuleHelpers

  alias AssertCommit.Assertions.Mix, as: MixAssertions
  alias AssertCommit.{Fixtures, Rules}

  setup_all do: %{repo: Fixtures.repo("library")}

  describe "Rules.Changelog :api_changes_logged" do
    test "passes when the unreleased section grew", %{repo: repo} do
      commit = scenario(repo, :api_added_with_changelog)
      assert %{added: [_], removed: []} = public_api_diff(commit)
      assert_pass(run_rule(Rules.Changelog, :api_changes_logged, commit))
    end

    test "fails naming the API change", %{repo: repo} do
      commit = scenario(repo, :api_added_without_changelog)
      [{m, f, a}] = public_api_diff(commit).added
      assert_fail(run_rule(Rules.Changelog, :api_changes_logged, commit), message)
      assert message =~ "the unreleased section of CHANGELOG.md did not"
      assert message =~ "#{inspect(m)}.#{f}/#{a} added"
    end

    test "is vacuous when the public API is unchanged", %{repo: repo} do
      commit = scenario(repo, :deps_changed_with_lock)
      refute public_api_changed?(commit)
      assert_pass(run_rule(Rules.Changelog, :api_changes_logged, commit))
    end

    test "honours a custom path", %{repo: repo} do
      assert_fail(
        run_rule(Rules.Changelog, :api_changes_logged, scenario(repo, :api_added_with_changelog),
          path: "HISTORY.md"
        ),
        message
      )

      assert message =~ "HISTORY.md has no unreleased section"
    end
  end

  describe "Rules.Elixir :specs" do
    test "passes", %{repo: repo} do
      assert_pass(run_rule(Rules.Elixir, :specs, scenario(repo, :api_added_with_changelog)))
    end

    test "fails naming the function", %{repo: repo} do
      commit = scenario(repo, :api_added_without_spec)
      [{m, f, a}] = public_api_diff(commit).added
      assert_fail(run_rule(Rules.Elixir, :specs, commit), message)
      assert message =~ "have no @spec:\n  #{inspect(m)}.#{f}/#{a}"
    end
  end

  describe "removing a public function" do
    test "Rules.Elixir :removals_deprecated fails because it was never deprecated", %{repo: repo} do
      commit = scenario(repo, :function_removed_with_breaking_trailer)
      [{m, f, a}] = public_api_diff(commit).removed
      assert_fail(run_rule(Rules.Elixir, :removals_deprecated, commit), message)
      assert message =~ "removed without a prior @deprecated:\n  #{inspect(m)}.#{f}/#{a}"
    end

    test "Rules.Elixir :removals_deprecated is vacuous when nothing was removed", %{repo: repo} do
      assert_pass(
        run_rule(Rules.Elixir, :removals_deprecated, scenario(repo, :api_added_with_changelog))
      )
    end

    test "a Rules.Message trailer requirement can demand BREAKING CHANGE on removals", %{
      repo: repo
    } do
      trailers = [{&(public_api_diff(&1).removed != []), "BREAKING CHANGE", nil}]

      assert_pass(
        run_rule(
          Rules.Message,
          :trailers,
          scenario(repo, :function_removed_with_breaking_trailer),
          trailers: trailers
        )
      )

      assert_fail(
        run_rule(
          Rules.Message,
          :trailers,
          scenario(repo, :function_removed_without_breaking_trailer),
          trailers: trailers
        ),
        message
      )

      assert message =~ "Expected a `BREAKING CHANGE:` trailer, but the message has no trailers."

      assert_pass(
        run_rule(Rules.Message, :trailers, scenario(repo, :api_added_with_changelog),
          trailers: trailers
        )
      )
    end
  end

  describe "new modules" do
    test "Rules.ExUnit :tested and Rules.Elixir :moduledoc pass", %{repo: repo} do
      commit = scenario(repo, :new_module_with_test)
      assert_pass(run_rule(Rules.ExUnit, :tested, commit))
      assert_pass(run_rule(Rules.Elixir, :moduledoc, commit))
    end

    test "Rules.ExUnit :tested fails", %{repo: repo} do
      commit = scenario(repo, :new_module_without_test)
      [added] = modules_added(commit, ~r{^lib/})
      assert_fail(run_rule(Rules.ExUnit, :tested, commit), message)
      assert message =~ "have no test module"
      assert message =~ inspect(added)
    end

    test "Rules.Elixir :moduledoc fails", %{repo: repo} do
      commit = scenario(repo, :new_module_without_moduledoc)
      [added] = modules_added(commit, ~r{^lib/})
      assert_fail(run_rule(Rules.Elixir, :moduledoc, commit), message)
      assert message =~ "have no @moduledoc:\n  #{inspect(added)}"
    end
  end

  describe "Rules.Mix :lock_in_sync" do
    test "passes when the lockfile gained the dependency", %{repo: repo} do
      commit = scenario(repo, :deps_changed_with_lock)
      assert [%{name: name}] = MixAssertions.deps_added(commit)
      assert name in AssertCommit.MixFile.locked(commit.after)
      assert_pass(run_rule(Rules.Mix, :lock_in_sync, commit))
    end

    test "fails naming the missing lock entry", %{repo: repo} do
      commit = scenario(repo, :deps_changed_without_lock)
      [%{name: name}] = MixAssertions.deps_added(commit)
      assert_fail(run_rule(Rules.Mix, :lock_in_sync, commit), message)
      assert message =~ "#{inspect(name)} was added to mix.exs but is not in mix.lock"
      assert message =~ "Run `mix deps.get`"
    end

    test "is vacuous when deps are unchanged", %{repo: repo} do
      commit = scenario(repo, :api_added_with_changelog)
      assert MixAssertions.deps_added(commit) == []
      assert_pass(run_rule(Rules.Mix, :lock_in_sync, commit))
    end
  end

  describe "Rules.Changelog :release_logged" do
    test "passes for a clean release", %{repo: repo} do
      commit = scenario(repo, :release_commit)
      assert {_, new} = MixAssertions.version_bump(commit)
      assert AssertCommit.Changelog.section_for(commit.after, new)
      assert_pass(run_rule(Rules.Changelog, :release_logged, commit))
    end

    test "fails without a section for the version", %{repo: repo} do
      commit = scenario(repo, :version_bump_without_changelog_heading)
      {_, new} = MixAssertions.version_bump(commit)
      assert_fail(run_rule(Rules.Changelog, :release_logged, commit), message)
      assert message =~ "has no `## #{new}` section"
    end

    test "is vacuous for non-release commits", %{repo: repo} do
      commit = scenario(repo, :api_added_with_changelog)
      assert MixAssertions.version_bump(commit) == nil
      assert_pass(run_rule(Rules.Changelog, :release_logged, commit))
    end

    # A project rule set composed from the generic verbs: releases touch only release metadata.
    defmodule ReleaseRules do
      use AssertCommit.RuleSet

      import AssertCommit.Assertions
      import AssertCommit.Assertions.Mix

      rule :release_only, "a version bump touches only release metadata", fn commit ->
        if version_bump(commit), do: refute_touched(commit, ~r{^(lib|test)/}), else: :ok
      end
    end

    test "a custom rule set catches code riding along with a release", %{repo: repo} do
      assert_pass(run_rule(ReleaseRules, :release_only, scenario(repo, :release_commit)))

      assert_fail(
        run_rule(ReleaseRules, :release_only, scenario(repo, :release_commit_with_code)),
        message
      )

      assert message =~ "but it touches:\n  lib/"
    end
  end
end
