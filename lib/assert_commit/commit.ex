defmodule AssertCommit.Commit do
  @moduledoc """
  A change set: the trees before and after, the per-file changes between
  them, and (for real commits) the metadata and message.

  Build one with `head/1`, `rev/2`, `staged/1`, or `new/1` for a synthetic
  change set in tests. All four produce the same struct, so assertions do
  not care where a commit came from.
  """

  alias AssertCommit.{FileChange, Git, Message, Tree}
  alias AssertCommit.{MergeCommitError, ShallowCloneError}
  alias AssertCommit.Source.Diff

  @enforce_keys [:source, :before, :after, :changes]
  defstruct source: nil,
            sha: nil,
            parents: [],
            author: nil,
            committer: nil,
            message: nil,
            before: nil,
            after: nil,
            changes: [],
            elixir: nil,
            base: nil,
            repo: nil

  @type person :: %{name: String.t(), email: String.t(), date: DateTime.t()}

  @type t :: %__MODULE__{
          source: :head | :rev | :staged | :worktree | :synthetic,
          sha: String.t() | nil,
          parents: [String.t()],
          author: person() | nil,
          committer: person() | nil,
          message: Message.t() | nil,
          before: Tree.t(),
          after: Tree.t(),
          changes: [FileChange.t()],
          elixir: Diff.t() | nil,
          base: String.t() | nil,
          repo: Path.t() | nil
        }

  @doc """
  Loads `HEAD` of the repository at `opts[:repo]` (default: the current directory).
  """
  @spec head(keyword()) :: t()
  def head(opts \\ []), do: %{rev("HEAD", opts) | source: :head}

  @doc """
  Loads the commit named by `rev` (any revision git understands).

  Raises `AssertCommit.MergeCommitError` for merge commits and
  `AssertCommit.ShallowCloneError` when the parent is not present locally.
  """
  @spec rev(String.t(), keyword()) :: t()
  def rev(rev, opts \\ []) do
    repo = repo_path(opts)

    info =
      case Git.commit_info(repo, rev) do
        {:ok, info} -> info
        {:error, error} -> raise error
      end

    before_oid =
      case info.parents do
        [] ->
          if Git.shallow_boundary?(repo, info.sha) do
            raise ShallowCloneError, sha: info.sha, parent: nil
          end

          Git.empty_tree(repo)

        [parent] ->
          unless Git.object_present?(repo, parent <> "^{commit}") do
            raise ShallowCloneError, sha: info.sha, parent: parent
          end

          parent <> "^{tree}"

        parents ->
          raise MergeCommitError, sha: info.sha, parents: parents
      end

    {before, after_tree, changes} =
      git_changes(repo, Tree.from_git(repo, before_oid), Tree.from_git(repo, info.tree))

    with_diff(%__MODULE__{
      source: :rev,
      repo: repo,
      sha: info.sha,
      parents: info.parents,
      author: info.author,
      committer: info.committer,
      message: Message.parse(info.body),
      before: before,
      after: after_tree,
      changes: changes
    })
  end

  @doc """
  Loads the staged index of the repository at `opts[:repo]` as a change set
  against `HEAD`, or against `opts[:base]` (any tree-ish) when given.

  The result has no `sha` or `message`; message assertions raise
  `AssertCommit.NoMessageError`. On an unborn branch the before tree is empty.

  `base:` is what an amend needs: measured against `HEAD^`, the index is the
  commit that `git commit --amend` will produce.
  """
  @spec staged(keyword()) :: t()
  def staged(opts \\ []) do
    repo = repo_path(opts)

    after_oid =
      case Git.write_index_tree(repo) do
        {:ok, oid} -> oid
        {:error, error} -> raise error
      end

    against_base(repo, after_oid, Keyword.get(opts, :base))
  end

  defp against_base(repo, after_oid, base) do
    before_oid =
      case Git.rev_parse(repo, "#{base || "HEAD"}^{tree}") do
        {:ok, oid} -> oid
        # Without an explicit base, no HEAD means an unborn branch: measure against the empty tree.
        {:error, _} when is_nil(base) -> Git.empty_tree(repo)
        {:error, error} -> raise error
      end

    {before, after_tree, changes} =
      git_changes(repo, Tree.from_git(repo, before_oid), Tree.from_git(repo, after_oid))

    with_diff(%__MODULE__{
      source: :staged,
      repo: repo,
      base: base,
      before: before,
      after: after_tree,
      changes: changes
    })
  end

  @doc """
  Loads the working directory of the repository at `opts[:repo]` as a change
  set against `HEAD`: staged and unstaged edits and untracked files alike.

  Like `staged/1`, the result has no `sha` or `message` and accepts `base:`.
  The repository's index is not touched (see `AssertCommit.Git.write_worktree_tree/1`).
  """
  @spec worktree(keyword()) :: t()
  def worktree(opts \\ []) do
    repo = repo_path(opts)

    after_oid =
      case Git.write_worktree_tree(repo) do
        {:ok, oid} -> oid
        {:error, error} -> raise error
      end

    %{against_base(repo, after_oid, Keyword.get(opts, :base)) | source: :worktree}
  end

  @doc """
  The same change set restricted to changes whose path matches `pattern`.

  The before and after trees are left whole, so tree-wide invariants still
  see the whole repository; only the changes — and the structural diff
  derived from them — are narrowed.
  """
  @spec restrict(t(), AssertCommit.Pattern.t()) :: t()
  def restrict(%__MODULE__{changes: changes} = commit, pattern) do
    kept = Enum.filter(changes, &AssertCommit.Pattern.matches?(&1.path, pattern))
    with_diff(%{commit | changes: kept})
  end

  @doc """
  Builds a synthetic change set from in-memory trees.

  ## Options

  - `:before` — map of path to contents for the parent tree (default: empty).
  - `:after` — map of path to contents for the resulting tree (required).
  - `:renames` — list of `{old_path, new_path}` pairs. Without this, a
    moved file is reported as a deletion plus an addition, exactly as git
    would without rename detection.
  - `:message` — raw commit message; omit for a message-less change set.

  ## Examples

      Commit.new(
        before: %{"lib/a.ex" => "defmodule A do\\nend\\n"},
        after: %{"lib/a.ex" => "defmodule A do\\n  def x, do: 1\\nend\\n"},
        message: "[a] add x/0"
      )
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    before_files = Keyword.get(opts, :before, %{})
    after_files = Keyword.fetch!(opts, :after)
    renames = Keyword.get(opts, :renames, [])

    before = Tree.from_map(before_files)
    after_tree = Tree.from_map(after_files)

    changes = synthetic_changes(before_files, after_files, renames, before, after_tree)

    with_diff(%__MODULE__{
      source: :synthetic,
      sha: Keyword.get(opts, :sha),
      message: opts |> Keyword.get(:message) |> then(&if(&1, do: Message.parse(&1))),
      before: before,
      after: after_tree,
      changes: changes
    })
  end

  # The structural diff only depends on the changed Elixir files, so it is computed once at load.
  defp with_diff(%__MODULE__{} = commit), do: %{commit | elixir: Diff.compute(commit)}

  defp repo_path(opts), do: opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand()

  # Returns the prefetched trees along with the changes: every changed blob is read once, in bulk.
  defp git_changes(repo, before, after_tree) do
    entries =
      case Git.diff_trees(repo, before.oid, after_tree.oid) do
        {:ok, entries} -> entries
        {:error, error} -> raise error
      end

    # Submodule pointers (mode 160000) are not files.
    entries = Enum.reject(entries, &("160000" in [&1.old_mode, &1.new_mode]))
    before = Tree.prefetch(before, for(e <- entries, e.old_path, do: e.old_path))
    after_tree = Tree.prefetch(after_tree, for(e <- entries, e.new_path, do: e.new_path))

    changes =
      Enum.map(entries, fn entry ->
        {path, old_path} =
          case entry.status do
            :deleted -> {entry.old_path, nil}
            s when s in [:renamed, :copied] -> {entry.new_path, entry.old_path}
            _ -> {entry.new_path, nil}
          end

        FileChange.build(entry.status, path, old_path, before, after_tree,
          similarity: entry.score
        )
      end)

    {before, after_tree, changes}
  end

  defp synthetic_changes(before_files, after_files, renames, before, after_tree) do
    renamed_from = MapSet.new(renames, &elem(&1, 0))
    renamed_to = MapSet.new(renames, &elem(&1, 1))

    renamed =
      for {old, new} <- renames do
        FileChange.build(:renamed, new, old, before, after_tree, similarity: 100)
      end

    added =
      for {path, _} <- after_files,
          not Map.has_key?(before_files, path),
          not MapSet.member?(renamed_to, path),
          do: FileChange.build(:added, path, nil, before, after_tree)

    deleted =
      for {path, _} <- before_files,
          not Map.has_key?(after_files, path),
          not MapSet.member?(renamed_from, path),
          do: FileChange.build(:deleted, path, nil, before, after_tree)

    modified =
      for {path, old_contents} <- before_files,
          {:ok, new_contents} <- [Map.fetch(after_files, path)],
          old_contents != new_contents,
          do: FileChange.build(:modified, path, nil, before, after_tree)

    Enum.sort_by(renamed ++ added ++ deleted ++ modified, & &1.path)
  end
end
