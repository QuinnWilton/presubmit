# Commit policy for presubmit itself; run with `mix presubmit`.
[
  # `:removals_deprecated` returns once 0.1.0 is published; until then the API is unreleased.
  {Presubmit.Rules.Elixir, except: [:removals_deprecated]},
  Presubmit.Rules.Hygiene,
  Presubmit.Rules.Mix,
  Presubmit.Rules.Changelog,
  # `:tested` is not applied: the assertion modules are exercised by the scenario suites
  # through rule sets, which the ExUnit adapter cannot see as a reference to them.
  {Presubmit.Rules.ExUnit, only: [:behaviour_changes_tested]},
  {Presubmit.Rules.Message,
   subject: ~r/^\[[a-z_-]+\] [a-z]/,
   max_subject_length: 72,
   trailers: [
     {fn commit ->
        Enum.any?(
          Presubmit.Query.trailer(commit, "Co-Authored-By"),
          &(&1 =~ ~r/anthropic\.com/)
        )
      end, "Claude-Session", ~r{^https://claude\.ai/code/session_}}
   ]},
  {Presubmit.Rules.Shape, max_files: 60, max_additions: 3000}
]
