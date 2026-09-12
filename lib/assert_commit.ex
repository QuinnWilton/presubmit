defmodule AssertCommit do
  @moduledoc """
  Assertions over the shape and contents of git commits, run as a linter.

  `mix assert_commit` loads a change set — a commit, the staged index, or the
  working tree — parses the Elixir it changed into a structural description,
  and runs the rules in `.assert_commit.exs` against it. See
  `Mix.Tasks.AssertCommit` for the command line and `AssertCommit.RuleSet`
  for writing rules.

  Programmatic use:

      commit = AssertCommit.load(source: :auto)
      report = AssertCommit.Runner.run(commit, AssertCommit.Config.load!().rules)
  """

  alias AssertCommit.{Commit, Git, Message}

  @type source :: :auto | :head | :staged | :worktree | {:rev, String.t()}

  @doc """
  Loads a change set.

  ## Options

  - `:repo` — repository path (default: the current directory).
  - `:source` — `:head` (default), `{:rev, rev}`, `:staged`, `:worktree`, or
    `:auto`, which is `:worktree` when anything on disk differs from `HEAD`
    and `:head` otherwise.
  - `:message` — raw message text to attach to a `:staged` or `:worktree`
    change set (from a `commit-msg` hook, say), cleaned as git would.
  - `:base` — tree-ish to measure a `:staged` or `:worktree` change set
    against instead of `HEAD` (`"HEAD^"` while amending).
  """
  @spec load(keyword()) :: Commit.t()
  def load(opts \\ []) do
    commit =
      case resolve_source(opts) do
        :head -> Commit.head(opts)
        {:rev, rev} -> Commit.rev(rev, opts)
        :staged -> Commit.staged(opts)
        :worktree -> Commit.worktree(opts)
      end

    case Keyword.get(opts, :message) do
      nil -> commit
      text when is_binary(text) -> %{commit | message: text |> Message.clean() |> Message.parse()}
    end
  end

  @doc "The concrete source `:auto` would pick for `opts[:repo]` right now."
  @spec resolve_source(keyword()) :: :head | :staged | :worktree | {:rev, String.t()}
  def resolve_source(opts \\ []) do
    case Keyword.get(opts, :source, :head) do
      :auto ->
        repo = opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand()
        if Git.dirty?(repo), do: :worktree, else: :head

      source ->
        source
    end
  end
end
