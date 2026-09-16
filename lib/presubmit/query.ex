defmodule Presubmit.Query do
  @moduledoc """
  Functions that read facts out of a `Presubmit.Commit` for use in
  assertions or directly in tests.

  Queries return data; the assertion verbs are built on top of them.
  Path-level queries work on any file; the Elixir-level ones read the
  structural diff (`Presubmit.Source.Diff`) and adapter models
  (`Presubmit.Source.models/2`).
  """

  alias Presubmit.{Commit, FileChange, Hunk, Message, NoMessageError, Pattern, Tree}
  alias Presubmit.Source.Diff
  alias Presubmit.Source.Facts.{Function, Module}

  @type pattern :: Pattern.t()

  ## Paths

  @doc "Changes whose status is one of `statuses` and whose path matches `pattern`."
  @spec changes(Commit.t(), [FileChange.status()] | :any, pattern()) :: [FileChange.t()]
  def changes(%Commit{changes: changes}, statuses, pattern \\ nil) do
    Enum.filter(changes, fn change ->
      (statuses == :any or change.status in statuses) and Pattern.matches?(change.path, pattern)
    end)
  end

  @doc "Paths of files added by the commit."
  @spec added(Commit.t(), pattern()) :: [String.t()]
  def added(commit, pattern \\ nil), do: paths(commit, [:added, :copied], pattern)

  @doc "Paths of files whose contents changed in place."
  @spec modified(Commit.t(), pattern()) :: [String.t()]
  def modified(commit, pattern \\ nil), do: paths(commit, [:modified, :type_changed], pattern)

  @doc "Paths of files deleted by the commit."
  @spec removed(Commit.t(), pattern()) :: [String.t()]
  def removed(commit, pattern \\ nil), do: paths(commit, [:deleted], pattern)

  @doc "`{old_path, new_path}` pairs for renamed files; `pattern` matches either side."
  @spec renamed(Commit.t(), pattern()) :: [{String.t(), String.t()}]
  def renamed(%Commit{changes: changes}, pattern \\ nil) do
    for %FileChange{status: :renamed, old_path: old, path: new} <- changes,
        Pattern.matches?(old, pattern) or Pattern.matches?(new, pattern),
        do: {old, new}
  end

  @doc """
  Every path the commit touches, matching `pattern`.

  Renames contribute both their old and new paths.
  """
  @spec touched(Commit.t(), pattern()) :: [String.t()]
  def touched(%Commit{changes: changes}, pattern \\ nil) do
    changes
    |> Enum.flat_map(fn change ->
      Enum.reject([FileChange.before_path(change), FileChange.after_path(change)], &is_nil/1)
    end)
    |> Enum.uniq()
    |> Enum.filter(&Pattern.matches?(&1, pattern))
  end

  @doc "Whether the commit touches any path matching `pattern`."
  @spec touches?(Commit.t(), pattern()) :: boolean()
  def touches?(commit, pattern), do: touched(commit, pattern) != []

  @doc "Whether `path` exists in the after tree."
  @spec exists?(Commit.t(), String.t()) :: boolean()
  def exists?(%Commit{after: tree}, path), do: Tree.exists?(tree, path)

  @doc "Paths in the after tree matching `pattern`, sorted."
  @spec after_paths(Commit.t(), pattern()) :: [String.t()]
  def after_paths(%Commit{after: tree}, pattern \\ nil) do
    tree |> Tree.paths() |> Enum.filter(&Pattern.matches?(&1, pattern))
  end

  @doc "Paths in the before tree matching `pattern`, sorted."
  @spec before_paths(Commit.t(), pattern()) :: [String.t()]
  def before_paths(%Commit{before: tree}, pattern \\ nil) do
    tree |> Tree.paths() |> Enum.filter(&Pattern.matches?(&1, pattern))
  end

  defp paths(commit, statuses, pattern) do
    commit |> changes(statuses, pattern) |> Enum.map(& &1.path)
  end

  ## Lines

  @doc """
  Lines added by the commit as `{path, line_number, text}`, for files
  matching `pattern`. Line numbers refer to the after tree.
  """
  @spec added_lines(Commit.t(), pattern()) :: [{String.t(), pos_integer(), String.t()}]
  def added_lines(commit, pattern \\ nil) do
    for change <- changes(commit, :any, pattern),
        {no, text} <- Hunk.added_lines(change.hunks),
        do: {change.path, no, text}
  end

  @doc """
  Lines removed by the commit as `{path, line_number, text}`. Line numbers
  refer to the before tree and the path is the before path.
  """
  @spec removed_lines(Commit.t(), pattern()) :: [{String.t(), pos_integer(), String.t()}]
  def removed_lines(commit, pattern \\ nil) do
    for change <- changes(commit, :any, pattern),
        path = FileChange.before_path(change),
        {no, text} <- Hunk.removed_lines(change.hunks),
        do: {path, no, text}
  end

  @doc "Total lines added across the commit."
  @spec additions(Commit.t()) :: non_neg_integer()
  def additions(%Commit{changes: changes}), do: changes |> Enum.map(& &1.additions) |> Enum.sum()

  @doc "Total lines removed across the commit."
  @spec deletions(Commit.t()) :: non_neg_integer()
  def deletions(%Commit{changes: changes}), do: changes |> Enum.map(& &1.deletions) |> Enum.sum()

  @doc """
  Whether the commit only changes whitespace: no files added, removed, or
  renamed, and every modified file's non-whitespace bytes are unchanged.
  """
  @spec formatting_only?(Commit.t()) :: boolean()
  def formatting_only?(%Commit{changes: changes}) do
    changes != [] and
      Enum.all?(changes, fn change ->
        change.status == :modified and not change.binary? and
          squash(Hunk.removed_lines(change.hunks)) == squash(Hunk.added_lines(change.hunks))
      end)
  end

  defp squash(lines), do: lines |> Enum.map_join(&elem(&1, 1)) |> String.replace(~r/\s+/, "")

  ## Elixir source

  @doc "The structural diff of the commit's Elixir source."
  @spec elixir_diff(Commit.t()) :: Diff.t()
  def elixir_diff(%Commit{} = commit), do: Presubmit.Source.diff(commit)

  @doc "Modules the commit defines in files matching `pattern` that did not exist before (renames excluded)."
  @spec modules_added(Commit.t(), pattern()) :: [module()]
  def modules_added(commit, pattern \\ nil),
    do: commit |> module_facts_added(pattern) |> Enum.map(& &1.name)

  @doc "Modules that existed before the commit and do not after (renames excluded)."
  @spec modules_removed(Commit.t(), pattern()) :: [module()]
  def modules_removed(commit, pattern \\ nil) do
    for m <- elixir_diff(commit).modules.removed, Pattern.matches?(m.path, pattern), do: m.name
  end

  @doc "`{old, new}` module names for modules the commit renamed."
  @spec modules_renamed(Commit.t()) :: [{module(), module()}]
  def modules_renamed(commit) do
    for {old, new} <- elixir_diff(commit).modules.renamed, do: {old.name, new.name}
  end

  @doc "Facts for every module the commit adds in files matching `pattern`."
  @spec module_facts_added(Commit.t(), pattern()) :: [Module.t()]
  def module_facts_added(commit, pattern \\ nil) do
    Enum.filter(elixir_diff(commit).modules.added, &Pattern.matches?(&1.path, pattern))
  end

  @doc "Functions the commit adds in files matching `pattern`, public and private."
  @spec functions_added(Commit.t(), pattern()) :: [Function.t()]
  def functions_added(commit, pattern \\ nil) do
    Enum.filter(elixir_diff(commit).functions.added, &Pattern.matches?(&1.path, pattern))
  end

  @doc "Functions the commit removes from files matching `pattern`, public and private."
  @spec functions_removed(Commit.t(), pattern()) :: [Function.t()]
  def functions_removed(commit, pattern \\ nil) do
    Enum.filter(elixir_diff(commit).functions.removed, &Pattern.matches?(&1.path, pattern))
  end

  @doc """
  Public functions added and removed by the commit, as `{module, name, arity}`.

  A function whose arity set changes shows up as removed at the old arity
  and added at the new one.
  """
  @spec public_api_diff(Commit.t()) :: %{
          added: [{module(), atom(), arity()}],
          removed: [{module(), atom(), arity()}]
        }
  def public_api_diff(commit) do
    diff = elixir_diff(commit)
    %{added: Diff.public_added(diff), removed: Diff.public_removed(diff)}
  end

  @doc "Whether any public function was added or removed."
  @spec public_api_changed?(Commit.t()) :: boolean()
  def public_api_changed?(commit), do: commit |> elixir_diff() |> Diff.public_api_changed?()

  @doc """
  Whether any function's body changed or any function was added or removed,
  in files matching `pattern`.

  Docs, specs, attributes, and formatting do not count, which makes this the
  right trigger for "code changes need test changes".
  """
  @spec behaviour_changed?(Commit.t(), pattern()) :: boolean()
  def behaviour_changed?(commit, pattern \\ nil) do
    %{added: added, removed: removed, body_changed: body_changed} =
      function_changes(commit, pattern)

    added != [] or removed != [] or body_changed != []
  end

  @doc "Functions added, removed, and body-changed in files matching `pattern`."
  @spec function_changes(Commit.t(), pattern()) :: %{
          added: [Function.t()],
          removed: [Function.t()],
          body_changed: [{Function.t(), Function.t()}]
        }
  def function_changes(commit, pattern \\ nil) do
    %{functions: f} = elixir_diff(commit)

    %{
      added: Enum.filter(f.added, &Pattern.matches?(&1.path, pattern)),
      removed: Enum.filter(f.removed, &Pattern.matches?(&1.path, pattern)),
      body_changed:
        Enum.filter(f.body_changed, fn {_, new} -> Pattern.matches?(new.path, pattern) end)
    }
  end

  @doc "Elixir files the commit could not parse, with the parser's reason."
  @spec unparsed(Commit.t()) :: [{String.t(), term()}]
  def unparsed(commit), do: elixir_diff(commit).unparsed

  ## Message

  @doc "Whether this change set carries a commit message."
  @spec has_message?(Commit.t()) :: boolean()
  def has_message?(%Commit{message: message}), do: not is_nil(message)

  @doc "The parsed message, raising `Presubmit.NoMessageError` if there is none."
  @spec message!(Commit.t()) :: Message.t()
  def message!(%Commit{message: nil, source: source}), do: raise(NoMessageError, source: source)
  def message!(%Commit{message: message}), do: message

  @doc "The subject line."
  @spec subject(Commit.t()) :: String.t()
  def subject(commit), do: message!(commit).subject

  @doc "All trailers as `{key, value}` pairs."
  @spec trailers(Commit.t()) :: [Message.trailer()]
  def trailers(commit), do: message!(commit).trailers

  @doc "Values of the trailer `key` (case-insensitive)."
  @spec trailer(Commit.t(), String.t()) :: [String.t()]
  def trailer(commit, key), do: Message.trailer_values(message!(commit), key)
end
