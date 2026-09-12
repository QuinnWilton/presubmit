defmodule AssertCommit.Rules.Changelog do
  @moduledoc "Changelog: API changes and releases are recorded. Option `path:` (default `CHANGELOG.md`)."
  use AssertCommit.RuleSet, requires: [{:file, "CHANGELOG.md"}]

  import AssertCommit.Assertions.Changelog

  rule :api_changes_logged, "public API changes are recorded in the changelog", fn commit, opts ->
    assert_api_changes_logged(commit, Keyword.get(opts, :path, "CHANGELOG.md"))
  end

  rule :release_logged, "version bumps have a changelog section", fn commit, opts ->
    assert_release_logged(commit, Keyword.get(opts, :path, "CHANGELOG.md"))
  end
end
