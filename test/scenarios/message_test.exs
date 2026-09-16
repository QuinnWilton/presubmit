defmodule Presubmit.Scenarios.MessageTest do
  @moduledoc """
  `Rules.Message` run against `fixtures/message`: a multi-project repository
  whose `[component]` subjects must agree with the paths touched, whose
  LLM-assisted commits must be attributed, and whose tooling manifest can
  only change with the tooling's trailer.
  """

  use ExUnit.Case, async: true

  import Presubmit.Query
  import Presubmit.RuleHelpers

  alias Presubmit.{Fixtures, Rules}

  setup_all do: %{repo: Fixtures.repo("message")}

  # A `[component]` commit may touch that component's directory; `[workspace]` may touch anything.
  defp scope_opts do
    paths = fn
      "workspace" -> nil
      "deps" -> [~r{^\.tooling/}, "mix.lock"]
      component -> ~r{^#{Regex.escape(component)}/}
    end

    [scope: {~r/^\[(\w+)\]/, paths}]
  end

  # A Co-Authored-By naming the model is the trigger; the session link is the required companion.
  defp llm_opts do
    llm? = fn commit ->
      Enum.any?(trailer(commit, "Co-Authored-By"), &(&1 =~ ~r/anthropic\.com/))
    end

    [trailers: [{llm?, "Claude-Session", ~r{^https://claude\.ai/code/session_}}]]
  end

  defp tooling_opts, do: [trailers: [{&touches?(&1, ~r{^\.tooling/}), "Tooling", nil}]]

  describe ":scope" do
    test "passes", %{repo: repo} do
      assert_pass run_rule(Rules.Message, :scope, scenario(repo, :scoped_correctly), scope_opts())
    end

    test "fails when the diff is in another component", %{repo: repo} do
      commit = scenario(repo, :scope_mismatch)
      [scope] = Regex.run(~r/^\[(\w+)\]/, subject(commit), capture: :all_but_first)
      [path] = touched(commit)
      assert_fail run_rule(Rules.Message, :scope, commit, scope_opts()), message
      assert message =~ "scopes this commit to #{inspect(scope)}"
      assert message =~ "but it also touches:\n  #{path}"
    end

    test "fails when there is no scope at all", %{repo: repo} do
      assert_fail run_rule(Rules.Message, :scope, scenario(repo, :no_scope), scope_opts()),
                  message

      assert message =~ "Expected the subject to declare a scope"
    end

    test "catches a commit spanning two components", %{repo: repo} do
      commit = scenario(repo, :multi_project)
      assert length(touched(commit)) == 2
      assert_fail run_rule(Rules.Message, :scope, commit, scope_opts()), _
    end

    test "is skipped when not configured", %{repo: repo} do
      assert {:skip, "no scope: option configured"} =
               run_rule(Rules.Message, :scope, scenario(repo, :no_scope))
    end
  end

  describe ":trailers for LLM-assisted commits" do
    test "passes with both trailers", %{repo: repo} do
      commit = scenario(repo, :llm_commit_attributed)
      assert length(trailers(commit)) == 2
      assert_pass run_rule(Rules.Message, :trailers, commit, llm_opts())
    end

    test "fails without the session link", %{repo: repo} do
      assert_fail run_rule(
                    Rules.Message,
                    :trailers,
                    scenario(repo, :llm_commit_missing_session),
                    llm_opts()
                  ),
                  message

      assert message =~
               "Expected a `Claude-Session:` trailer, but the message has only: Co-Authored-By."
    end

    test "trailers followed by prose are not trailers, so the trigger never fires", %{repo: repo} do
      commit = scenario(repo, :trailers_not_last)
      assert trailers(commit) == []
      assert_pass run_rule(Rules.Message, :trailers, commit, llm_opts())

      # The generic verb explains why the block was not recognised.
      error =
        assert_raise Presubmit.Violation, fn ->
          Presubmit.Assertions.assert_trailer(commit, "Co-Authored-By")
        end

      assert error.message =~
               "Trailers are `Key: value` lines in the final paragraph of the message."
    end

    test "human commits are not required to carry the trailer", %{repo: repo} do
      assert_pass run_rule(
                    Rules.Message,
                    :trailers,
                    scenario(repo, :scoped_correctly),
                    llm_opts()
                  )
    end

    test "is skipped when not configured", %{repo: repo} do
      assert {:skip, "no trailers: option configured"} =
               run_rule(Rules.Message, :trailers, scenario(repo, :scoped_correctly))
    end
  end

  describe ":trailers for a tooling-owned file" do
    test "passes when the tooling trailer is present", %{repo: repo} do
      assert_pass run_rule(
                    Rules.Message,
                    :trailers,
                    scenario(repo, :manifest_via_tooling),
                    tooling_opts()
                  )
    end

    test "fails on a hand edit", %{repo: repo} do
      assert_fail run_rule(
                    Rules.Message,
                    :trailers,
                    scenario(repo, :manifest_hand_edit),
                    tooling_opts()
                  ),
                  message

      assert message =~ "Expected a `Tooling:` trailer"
    end

    test "is vacuous when the manifest is untouched", %{repo: repo} do
      assert_pass run_rule(
                    Rules.Message,
                    :trailers,
                    scenario(repo, :scoped_correctly),
                    tooling_opts()
                  )
    end
  end

  describe "subject hygiene" do
    test ":no_fixup refuses fixup!/squash! commits", %{repo: repo} do
      assert_fail run_rule(Rules.Message, :no_fixup, scenario(repo, :fixup)), message
      assert message =~ "not to match"
      assert_pass run_rule(Rules.Message, :no_fixup, scenario(repo, :scoped_correctly))
    end

    test ":subject_length defaults to 72 columns and is configurable", %{repo: repo} do
      assert_fail run_rule(Rules.Message, :subject_length, scenario(repo, :long_subject)), _

      assert_pass run_rule(Rules.Message, :subject_length, scenario(repo, :long_subject),
                    max_subject_length: 120
                  )

      assert_pass run_rule(Rules.Message, :subject_length, scenario(repo, :scoped_correctly))
    end

    test ":subject checks a configured pattern", %{repo: repo} do
      assert_pass run_rule(Rules.Message, :subject, scenario(repo, :scoped_correctly),
                    subject: ~r/^\[\w+\] /
                  )

      assert_fail run_rule(Rules.Message, :subject, scenario(repo, :no_scope),
                    subject: ~r/^\[\w+\] /
                  ),
                  _

      assert {:skip, _} = run_rule(Rules.Message, :subject, scenario(repo, :no_scope))
    end
  end
end
