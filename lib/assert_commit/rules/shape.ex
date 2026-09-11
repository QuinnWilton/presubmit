defmodule AssertCommit.Rules.Shape do
  @moduledoc """
  Commit size. Options `max_files:` (default 50) and `max_additions:` (default 1000).
  """
  use AssertCommit.RuleSet

  import AssertCommit.Assertions

  rule :max_files, "the commit changes a bounded number of files", fn commit, opts ->
    assert_max_files(commit, Keyword.get(opts, :max_files, 50))
  end

  rule :max_additions, "the commit adds a bounded number of lines", fn commit, opts ->
    assert_max_additions(commit, Keyword.get(opts, :max_additions, 1000))
  end
end
