defmodule AssertCommit.Rules.Hygiene do
  @moduledoc """
  Things that should never be committed. Options:

  - `debug:` — regex over added lines under `lib/` (default: `IO.inspect`, `dbg`, `IEx.pry`).
  - `artifacts:` — path patterns that must not be added (default: `.DS_Store`, `.orig`, `.rej`, `.beam`, `_build/`).
  """
  use AssertCommit.RuleSet

  import AssertCommit.Assertions

  @debug ~r/\b(IO\.inspect|dbg|IEx\.pry)\(/
  @artifacts [~r/\.DS_Store$/, ~r/\.(orig|rej|beam)$/, ~r{^_build/}]

  rule :no_debug_calls, "no debugging calls in lib/", fn commit, opts ->
    refute_added_lines(commit, Keyword.get(opts, :debug, @debug), in: ~r{^lib/})
  end

  rule :no_merge_markers,
       "no conflict markers",
       &refute_added_lines(&1, ~r/^(<{7}|={7}|>{7})( |$)/)

  rule :no_artifacts, "no build artifacts or editor droppings", fn commit, opts ->
    refute_added(commit, Keyword.get(opts, :artifacts, @artifacts))
  end
end
