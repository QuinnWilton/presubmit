defmodule AssertCommit.Rules.Message do
  @moduledoc """
  Commit message conventions. All of these skip for change sets without a message.

  Options:

  - `subject:` — regex the subject must match (rule `:subject`; skipped without it).
  - `max_subject_length:` — default 72 (rule `:subject_length`).
  - `scope:` — `{regex_with_capture, (scope -> path_pattern)}`; the subject's
    scope must agree with the paths touched (rule `:scope`; skipped without it).
  - `trailers:` — list of `{trigger, key, value_regex | nil}`; when `trigger`
    (a function of the commit) is true, the trailer must be present
    (rule `:trailers`; skipped without it).
  """
  use AssertCommit.RuleSet

  import AssertCommit.Assertions

  rule :no_fixup,
       "no fixup!/squash!/amend! commits",
       &refute_subject(&1, ~r/^(fixup|squash|amend)!/)

  rule :subject_length, "subject fits the configured length", fn commit, opts ->
    max = Keyword.get(opts, :max_subject_length, 72)
    assert_subject(commit, ~r/^.{1,#{max}}$/)
  end

  rule :subject, "subject matches the configured pattern", fn commit, opts ->
    case Keyword.get(opts, :subject) do
      nil -> {:skip, "no subject: pattern configured"}
      regex -> assert_subject(commit, regex)
    end
  end

  rule :scope, "subject scope matches the paths touched", fn commit, opts ->
    case Keyword.get(opts, :scope) do
      nil -> {:skip, "no scope: option configured"}
      {regex, path_pattern} -> assert_scope_matches_paths(commit, regex, path_pattern)
    end
  end

  rule :trailers, "required trailers are present", fn commit, opts ->
    case Keyword.get(opts, :trailers, []) do
      [] ->
        {:skip, "no trailers: option configured"}

      required ->
        for {trigger, key, regex} <- required,
            trigger.(commit),
            do: assert_trailer(commit, key, regex)

        :ok
    end
  end
end
