defmodule Mix.Tasks.AssertCommit do
  @shortdoc "Checks a commit, the index, or the working tree against the project's commit rules"

  @moduledoc """
  Runs the rules in `.assert_commit.exs` (or the built-in defaults) against a
  change set and reports each rule as passed, failed, or skipped.

      mix assert_commit                     # working tree if dirty, else HEAD
      mix assert_commit --head              # the commit at HEAD
      mix assert_commit --rev abc123
      mix assert_commit --staged            # from a pre-commit hook
      mix assert_commit --staged --message-file "$1"   # from a commit-msg hook: changes and message together
      mix assert_commit --worktree          # from an editor or agent loop
      mix assert_commit --range main..HEAD  # every commit on a branch
      mix assert_commit --format json
      mix assert_commit --list

  Exit status is 0 when every rule passed (or was skipped), 1 when any
  failed, and 2 on a usage or configuration error. The first line of output
  always names the source examined.

  Without a `.assert_commit.exs`, the defaults enable `Rules.Phoenix` and
  `Rules.Ecto` when those libraries are loaded or declared in `mix.exs`, and
  `Rules.Changelog` when a `CHANGELOG.md` exists; the output says what was
  enabled and why.

  A first commit that imports a whole codebase is not a normal commit; the
  shape and coverage rules will object. `git commit --no-verify` is the
  intended answer there, once.

  The project is not compiled: rules only parse source. Under CI, examining
  a dirty working tree prints a warning, since that usually means a build
  step modified the checkout; pass `--head` or `--rev` to gate the commit.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    # Put the project's dependencies on the code path so default detection can see
    # what is loaded (Phoenix, Ecto). The project itself is not compiled.
    try do
      Mix.Task.run("loadpaths", ["--no-compile"])
    rescue
      _ -> :ok
    end

    {status, output} = AssertCommit.CLI.main(argv)
    IO.write(output)
    if status != 0, do: exit({:shutdown, status})
  end
end
