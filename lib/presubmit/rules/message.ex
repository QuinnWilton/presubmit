defmodule Presubmit.Rules.Message do
  @moduledoc """
  Commit message conventions. All of these skip for change sets without a message.

  Subjects git writes itself — `Revert "…"` and `Merge …` — are exempt from
  the shape rules (`subject`, `subject_length`, `body_line_length`, `scope`);
  override with `exempt:` (a list of regexes, `[]` to exempt nothing).
  `no_fixup` applies to committed revisions only: `fixup!`/`squash!` commits
  are meant to exist locally and be autosquashed before they reach `main`.

  Options:

  - `subject:` — regex the subject must match (rule `:subject`; skipped without it).
  - `max_subject_length:` — default 72 characters, counted as graphemes (rule
    `:subject_length`). Many policies make it a warning: `warn: [:subject_length]`.
  - `max_body_line_length:` — default 72 characters, counted as graphemes (rule
    `:body_line_length`). Trailers are not measured, nor are body lines that
    wrapping could not bring within the limit: lines that start with
    whitespace (code, output) or `>` (quotes), `Key: value` lines with a
    one-word value, and lines whose last word (a URL, a path) is longer than
    the limit on its own. See `Presubmit.Assertions.assert_body_line_length/2`.
  - `scope:` — `{regex_with_capture, (scope -> path_pattern)}`; the subject's
    scope must agree with the paths touched (rule `:scope`; skipped without it).
  - `trailers:` — list of `{trigger, key, value_regex | nil}`; when `trigger`
    (a function of the commit) is true, the trailer must be present
    (rule `:trailers`; skipped without it).
  - `exempt:` — subjects the shape rules skip; default `[~r/^Revert "/, ~r/^Merge /]`.
  """
  use Presubmit.RuleSet

  import Presubmit.Assertions
  import Presubmit.Query

  @exempt [~r/^Revert "/, ~r/^Merge /]

  rule(
    :no_fixup,
    "no fixup!/squash!/amend! commits",
    &refute_subject(&1, ~r/^(fixup|squash|amend)!/),
    sources: [:head, :rev]
  )

  rule :subject_length, "subject fits the configured length", fn commit, opts ->
    unless_exempt(commit, opts, fn ->
      assert_subject_length(commit, Keyword.get(opts, :max_subject_length, 72))
    end)
  end

  rule :body_line_length, "body lines fit the configured length", fn commit, opts ->
    unless_exempt(commit, opts, fn ->
      assert_body_line_length(commit, Keyword.get(opts, :max_body_line_length, 72))
    end)
  end

  rule :subject, "subject matches the configured pattern", fn commit, opts ->
    case Keyword.get(opts, :subject) do
      nil -> {:skip, "no subject: pattern configured"}
      regex -> unless_exempt(commit, opts, fn -> assert_subject(commit, regex) end)
    end
  end

  rule :scope, "subject scope matches the paths touched", fn commit, opts ->
    case Keyword.get(opts, :scope) do
      nil ->
        {:skip, "no scope: option configured"}

      {regex, path_pattern} ->
        unless_exempt(commit, opts, fn ->
          assert_scope_matches_paths(commit, regex, path_pattern)
        end)
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

  defp unless_exempt(commit, opts, check) do
    subject = subject(commit)

    if Enum.any?(Keyword.get(opts, :exempt, @exempt), &Regex.match?(&1, subject)),
      do: {:skip, "git-generated subject: #{subject}"},
      else: check.()
  end
end
