defmodule AssertCommit.Git do
  @moduledoc """
  Thin adapter over the `git` plumbing commands assert_commit relies on.

  Every function takes the repository path first and returns tagged tuples;
  `run!/2` is the only place a shell command is executed. Keeping the surface
  this small is what lets the rest of the library be tested against
  in-memory trees.
  """

  alias AssertCommit.GitError

  @type repo :: Path.t()
  @type oid :: String.t()

  @typedoc """
  One record from `git diff-tree --raw`.

  `score` is the similarity percentage for renames and copies, `nil` otherwise.
  """
  @type raw_entry :: %{
          status: :added | :modified | :deleted | :renamed | :copied | :type_changed,
          old_path: String.t() | nil,
          new_path: String.t() | nil,
          old_mode: String.t(),
          new_mode: String.t(),
          score: non_neg_integer() | nil
        }

  @doc """
  Runs `git` with `args` inside `repo`, raising `AssertCommit.GitError` on
  a non-zero exit.

  Global and system git config are ignored so that the caller's aliases,
  signing settings, and hooks can't change plumbing output.
  """
  @spec run!(repo(), [String.t()]) :: binary()
  def run!(repo, args) do
    case run(repo, args) do
      {:ok, output} -> output
      {:error, %GitError{} = error} -> raise error
    end
  end

  @doc """
  Runs `git` with `args` inside `repo`.
  """
  @spec run(repo(), [String.t()], [{String.t(), String.t()}]) ::
          {:ok, binary()} | {:error, GitError.t()}
  def run(repo, args, env \\ []) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true, env: isolated_env() ++ env) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        {:error, %GitError{command: args, status: status, output: output, repo: repo}}
    end
  rescue
    e in ErlangError ->
      {:error,
       %GitError{
         command: args,
         status: nil,
         output: "could not execute git: #{Exception.message(e)}",
         repo: repo
       }}
  end

  @doc """
  Resolves `rev` to a full object id.
  """
  @spec rev_parse(repo(), String.t()) :: {:ok, oid()} | {:error, GitError.t()}
  def rev_parse(repo, rev) do
    with {:ok, out} <- run(repo, ["rev-parse", "--verify", "--quiet", rev <> "^{object}"]) do
      {:ok, String.trim(out)}
    end
  end

  @doc """
  Returns true when `rev` names an object that exists locally.
  """
  @spec object_present?(repo(), String.t()) :: boolean()
  def object_present?(repo, rev) do
    match?({:ok, _}, run(repo, ["cat-file", "-e", rev]))
  end

  @doc """
  Returns true when `sha` is a shallow-clone boundary: a commit whose real
  parents were cut off by `--depth`. Git reports such commits as parentless,
  so this is the only way to tell them apart from a genuine root commit.
  """
  @spec shallow_boundary?(repo(), oid()) :: boolean()
  def shallow_boundary?(repo, sha) do
    with {:ok, "true\n"} <- run(repo, ["rev-parse", "--is-shallow-repository"]),
         {:ok, path} <- run(repo, ["rev-parse", "--git-path", "shallow"]),
         {:ok, contents} <- File.read(Path.expand(String.trim(path), repo)) do
      sha in String.split(contents, "\n", trim: true)
    else
      _ -> false
    end
  end

  @doc """
  Returns the object id of the empty tree for this repository's hash algorithm.
  """
  @spec empty_tree(repo()) :: oid()
  def empty_tree(repo) do
    repo
    |> run!(["hash-object", "-t", "tree", "/dev/null"])
    |> String.trim()
  end

  @typedoc "Metadata for a single commit as read by `commit_info/2`."
  @type commit_info :: %{
          sha: oid(),
          tree: oid(),
          parents: [oid()],
          author: %{name: String.t(), email: String.t(), date: DateTime.t()},
          committer: %{name: String.t(), email: String.t(), date: DateTime.t()},
          body: String.t()
        }

  @doc """
  Reads commit metadata and the raw message body for `rev`.
  """
  @spec commit_info(repo(), String.t()) :: {:ok, commit_info()} | {:error, GitError.t()}
  def commit_info(repo, rev) do
    format = Enum.join(~w(%H %T %P %an %ae %aI %cn %ce %cI %B), "%x00")

    with {:ok, out} <- run(repo, ["log", "-1", "--format=" <> format, rev, "--"]) do
      [sha, tree, parents, an, ae, ad, cn, ce, cd, body] = String.split(out, "\0", parts: 10)

      {:ok,
       %{
         sha: sha,
         tree: tree,
         parents: String.split(parents, " ", trim: true),
         author: %{name: an, email: ae, date: parse_date(ad)},
         committer: %{name: cn, email: ce, date: parse_date(cd)},
         # git log appends a newline after %B.
         body: String.trim_trailing(body, "\n")
       }}
    end
  end

  @doc """
  Writes the current index to a tree object and returns its id.

  This is how the staged change set gets a tree that the rest of the
  pipeline can treat exactly like a commit's tree. Writing a tree object
  never touches refs or the working directory.
  """
  @spec write_index_tree(repo()) :: {:ok, oid()} | {:error, GitError.t()}
  def write_index_tree(repo) do
    with {:ok, out} <- run(repo, ["write-tree"]) do
      {:ok, String.trim(out)}
    end
  end

  @doc """
  Writes the working directory to a tree object and returns its id, without
  touching the repository's own index.

  A temporary index is seeded from `HEAD` (or left empty on an unborn
  branch), everything on disk is added to it honouring `.gitignore`, and the
  result is written as a tree. Only loose objects are created; `git gc`
  reclaims them.
  """
  @spec write_worktree_tree(repo()) :: {:ok, oid()} | {:error, GitError.t()}
  def write_worktree_tree(repo) do
    index =
      Path.join(System.tmp_dir!(), "assert_commit_index_#{System.unique_integer([:positive])}")

    env = [{"GIT_INDEX_FILE", index}]

    try do
      with :ok <- seed_index(repo, env),
           {:ok, _} <- run(repo, ["add", "-A", "--", "."], env),
           {:ok, out} <- run(repo, ["write-tree"], env) do
        {:ok, String.trim(out)}
      end
    after
      File.rm(index)
    end
  end

  defp seed_index(repo, env) do
    case run(repo, ["rev-parse", "--verify", "--quiet", "HEAD^{tree}"]) do
      {:ok, _} ->
        with {:ok, _} <- run(repo, ["read-tree", "HEAD"], env), do: :ok

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Whether anything on disk differs from `HEAD`: staged or unstaged edits, or
  untracked files that are not ignored.
  """
  @spec dirty?(repo()) :: boolean()
  def dirty?(repo) do
    case run(repo, ["status", "--porcelain", "--untracked-files=all"]) do
      {:ok, out} -> String.trim(out) != ""
      {:error, error} -> raise error
    end
  end

  @doc """
  Lists every blob path in `tree`.
  """
  @spec ls_tree(repo(), oid()) :: {:ok, [String.t()]} | {:error, GitError.t()}
  def ls_tree(repo, tree) do
    with {:ok, out} <- run(repo, ["ls-tree", "-r", "-z", "--name-only", tree]) do
      {:ok, String.split(out, "\0", trim: true)}
    end
  end

  @doc """
  Reads the blob at `path` in `tree`.
  """
  @spec read_blob(repo(), oid(), String.t()) :: {:ok, binary()} | :error
  def read_blob(repo, tree, path) do
    case run(repo, ["cat-file", "blob", tree <> ":" <> path]) do
      {:ok, blob} -> {:ok, blob}
      {:error, _} -> :error
    end
  end

  @doc """
  Diffs two trees with rename detection, returning one entry per changed path.
  """
  @spec diff_trees(repo(), oid(), oid()) :: {:ok, [raw_entry()]} | {:error, GitError.t()}
  def diff_trees(repo, before, after_tree) do
    args = ["diff-tree", "-r", "-z", "-M", "--raw", "--no-commit-id", before, after_tree]

    with {:ok, out} <- run(repo, args) do
      {:ok, parse_raw(String.split(out, "\0", trim: true))}
    end
  end

  # Raw records are `:<old_mode> <new_mode> <old_sha> <new_sha> <status>` followed by
  # one path (or two for renames and copies), each NUL-terminated.
  defp parse_raw([]), do: []

  defp parse_raw([":" <> header | rest]) do
    [old_mode, new_mode, _old_sha, _new_sha, status_field] = String.split(header, " ")
    {status, score} = parse_status(status_field)

    {paths, rest} =
      if status in [:renamed, :copied] do
        [old_path, new_path | rest] = rest
        {{old_path, new_path}, rest}
      else
        [path | rest] = rest
        {{path, path}, rest}
      end

    {old_path, new_path} = paths

    entry = %{
      status: status,
      old_path: if(status == :added, do: nil, else: old_path),
      new_path: if(status == :deleted, do: nil, else: new_path),
      old_mode: old_mode,
      new_mode: new_mode,
      score: score
    }

    [entry | parse_raw(rest)]
  end

  defp parse_status("A"), do: {:added, nil}
  defp parse_status("M"), do: {:modified, nil}
  defp parse_status("D"), do: {:deleted, nil}
  defp parse_status("T"), do: {:type_changed, nil}
  defp parse_status("R" <> score), do: {:renamed, String.to_integer(score)}
  defp parse_status("C" <> score), do: {:copied, String.to_integer(score)}

  defp parse_date(iso) do
    {:ok, date, _offset} = DateTime.from_iso8601(iso)
    date
  end

  defp isolated_env do
    [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"LC_ALL", "C"}
    ]
  end
end
