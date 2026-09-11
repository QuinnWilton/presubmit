# Commit policy for assert_commit itself; run with `mix assert_commit`.
[
  # `:removals_deprecated` returns once 0.1.0 is published; until then the API is unreleased.
  {AssertCommit.Rules.Elixir, except: [:removals_deprecated]},
  AssertCommit.Rules.Hygiene,
  AssertCommit.Rules.Mix,
  AssertCommit.Rules.Changelog,
  # `:tested` is not applied: the assertion modules are exercised by the scenario suites
  # through rule sets, which the ExUnit adapter cannot see as a reference to them.
  {AssertCommit.Rules.ExUnit, only: [:behaviour_changes_tested]},
  {AssertCommit.Rules.Message,
   subject: ~r/^\[[a-z_-]+\] [a-z]/,
   max_subject_length: 72,
   trailers: [
     {fn commit ->
        Enum.any?(
          AssertCommit.Query.trailer(commit, "Co-Authored-By"),
          &(&1 =~ ~r/anthropic\.com/)
        )
      end, "Claude-Session", ~r{^https://claude\.ai/code/session_}}
   ]},
  {AssertCommit.Rules.Shape, max_files: 60, max_additions: 3000}
]
