defmodule AssertCommit.Scenarios.MessageTest do
  @moduledoc """
  Content-aware message rules, run against `fixtures/message`: a
  multi-project repository whose `[component]` subjects must agree with
  the paths touched, whose LLM-assisted commits must be attributed, and
  whose tooling manifest can only change with the tooling's trailer.
  """

  use ExUnit.Case, async: true
  use AssertCommit, repo: & &1.repo, rev: &"scenario/#{&1.scenario}"

  setup_all do: %{repo: AssertCommit.Fixtures.repo("message")}

  @scope ~r/^\[(\w+)\]/
  # A `[component]` commit may touch that component's directory; `[workspace]` may touch anything.
  defp scope_paths("workspace"), do: nil
  defp scope_paths("deps"), do: [~r{^\.tooling/}, "mix.lock"]
  defp scope_paths(component), do: ~r{^#{Regex.escape(component)}/}

  describe "assert_scope_matches_paths/3" do
    @tag scenario: :scoped_correctly
    test "passes", %{commit: commit} do
      assert_scope_matches_paths(commit, @scope, &scope_paths/1)
    end

    @tag scenario: :scope_mismatch
    test "fails when the diff is in another component", %{commit: commit} do
      [scope] = Regex.run(@scope, subject(commit), capture: :all_but_first)
      [path] = touched(commit)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_scope_matches_paths(commit, @scope, &scope_paths/1)
        end

      assert error.message =~ "scopes this commit to #{inspect(scope)}"
      assert error.message =~ "but it also touches:\n  #{path}"
    end

    @tag scenario: :no_scope
    test "fails when there is no scope at all", %{commit: commit} do
      assert_raise ExUnit.AssertionError, ~r/Expected the subject to declare a scope/, fn ->
        assert_scope_matches_paths(commit, @scope, &scope_paths/1)
      end
    end

    @tag scenario: :multi_project
    test "catches a commit spanning two components", %{commit: commit} do
      assert length(touched(commit)) == 2

      assert_raise ExUnit.AssertionError, fn ->
        assert_scope_matches_paths(commit, @scope, &scope_paths/1)
      end
    end
  end

  describe "LLM-assisted commits are attributed" do
    # A Co-Authored-By naming the model is the trigger; the session link is the required companion.
    defp assert_llm_attribution(commit) do
      if Enum.any?(trailer(commit, "Co-Authored-By"), &(&1 =~ ~r/anthropic\.com/)) do
        assert_trailer(commit, "Claude-Session", ~r{^https://claude\.ai/code/session_})
      end
    end

    @tag scenario: :llm_commit_attributed
    test "passes with both trailers", %{commit: commit} do
      assert length(trailers(commit)) == 2
      assert_llm_attribution(commit)
    end

    @tag scenario: :llm_commit_missing_session
    test "fails without the session link", %{commit: commit} do
      error = assert_raise ExUnit.AssertionError, fn -> assert_llm_attribution(commit) end

      assert error.message =~
               "Expected a `Claude-Session:` trailer, but the message has only: Co-Authored-By."
    end

    @tag scenario: :trailers_not_last
    test "trailers followed by prose are not trailers, so the rule cannot see them", %{
      commit: commit
    } do
      assert trailers(commit) == []
      assert_llm_attribution(commit)

      error =
        assert_raise ExUnit.AssertionError, fn -> assert_trailer(commit, "Co-Authored-By") end

      assert error.message =~
               "Trailers are `Key: value` lines in the final paragraph of the message."
    end

    @tag scenario: :scoped_correctly
    test "human commits are not required to carry the trailer", %{commit: commit} do
      assert trailers(commit) == []
      assert_llm_attribution(commit)
    end
  end

  describe "the tooling manifest is only changed by tooling" do
    defp assert_manifest_changed_by_tooling(commit) do
      if touches?(commit, ~r{^\.tooling/}), do: assert_trailer(commit, "Tooling")
    end

    @tag scenario: :manifest_via_tooling
    test "passes when the tooling trailer is present", %{commit: commit} do
      assert_manifest_changed_by_tooling(commit)
    end

    @tag scenario: :manifest_hand_edit
    test "fails on a hand edit", %{commit: commit} do
      error =
        assert_raise ExUnit.AssertionError, fn -> assert_manifest_changed_by_tooling(commit) end

      assert error.message =~ "Expected a `Tooling:` trailer"
    end

    @tag scenario: :scoped_correctly
    test "is vacuous when the manifest is untouched", %{commit: commit} do
      assert_manifest_changed_by_tooling(commit)
    end
  end

  describe "subject hygiene" do
    @tag scenario: :fixup
    test "fixup!/squash! commits are refused", %{commit: commit} do
      assert_raise ExUnit.AssertionError, ~r/not to match/, fn ->
        refute_subject(commit, ~r/^(fixup|squash|amend)!/)
      end
    end

    @tag scenario: :long_subject
    test "subjects fit in 72 columns", %{commit: commit} do
      assert_raise ExUnit.AssertionError, ~r/Expected the subject to match/, fn ->
        assert_subject(commit, ~r/^.{1,72}$/)
      end
    end

    @tag scenario: :scoped_correctly
    test "a well-formed subject passes both", %{commit: commit} do
      refute_subject(commit, ~r/^(fixup|squash|amend)!/)
      assert_subject(commit, ~r/^.{1,72}$/)
    end
  end
end
