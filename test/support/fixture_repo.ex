defmodule AssertCommit.FixtureRepo do
  @moduledoc """
  Builds real git repositories in a temporary directory for integration tests.

  Every operation shells out to git with the user's global config ignored
  and fixed author/committer identities and dates, so fixture SHAs are
  deterministic across machines.

      repo = FixtureRepo.init!(tmp_dir)
      FixtureRepo.commit!(repo, message: "base", write: %{"lib/a.ex" => "..."})
      FixtureRepo.commit!(repo, message: "move", move: [{"lib/a.ex", "lib/b.ex"}])
      commit = FixtureRepo.head(repo)
  """

  alias AssertCommit.{Commit, Git}

  @enforce_keys [:path]
  defstruct [:path, clock: 0]

  @type t :: %__MODULE__{path: Path.t(), clock: non_neg_integer()}

  @doc "Initialises an empty repository with a `main` branch."
  @spec init!(Path.t()) :: t()
  def init!(dir) do
    path = Path.join(dir, "repo")
    File.mkdir_p!(path)
    git!(path, ["init", "-q", "-b", "main"])
    git!(path, ["config", "user.name", "Fixture"])
    git!(path, ["config", "user.email", "fixture@example.com"])
    git!(path, ["config", "commit.gpgsign", "false"])
    %__MODULE__{path: path}
  end

  @doc """
  Applies a change set to the working tree and stages it.

  ## Options

  - `:write` — map of path to contents (creates or overwrites).
  - `:remove` — list of paths to delete.
  - `:move` — list of `{old, new}` pairs; contents are preserved unless
    `new` also appears in `:write`.
  """
  @spec stage!(t(), keyword()) :: t()
  def stage!(%__MODULE__{path: path} = repo, opts) do
    for {old, new} <- Keyword.get(opts, :move, []) do
      dest = Path.join(path, new)
      File.mkdir_p!(Path.dirname(dest))
      File.rename!(Path.join(path, old), dest)
    end

    for file <- Keyword.get(opts, :remove, []), do: File.rm!(Path.join(path, file))

    for {file, contents} <- Keyword.get(opts, :write, %{}) do
      dest = Path.join(path, file)
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, contents)
    end

    git!(path, ["add", "-A"])
    repo
  end

  @doc """
  Stages a change set (see `stage!/2`) and commits it with `opts[:message]`.

  Each commit is one hour after the previous one, starting from a fixed epoch.
  """
  @spec commit!(t(), keyword()) :: t()
  def commit!(%__MODULE__{} = repo, opts) do
    repo = stage!(repo, opts)
    message = Keyword.fetch!(opts, :message)
    date = DateTime.add(~U[2026-01-01 00:00:00Z], repo.clock, :hour) |> DateTime.to_iso8601()

    message_file = Path.join(dir(repo), ".fixture_message")
    File.write!(message_file, message)

    git!(repo.path, ["commit", "-q", "--allow-empty", "-F", message_file],
      env: [{"GIT_AUTHOR_DATE", date}, {"GIT_COMMITTER_DATE", date}]
    )

    File.rm!(message_file)
    %{repo | clock: repo.clock + 1}
  end

  @doc "Loads `HEAD` of the fixture repository."
  @spec head(t()) :: Commit.t()
  def head(%__MODULE__{path: path}), do: Commit.head(repo: path)

  @doc "Loads the staged index of the fixture repository."
  @spec staged(t()) :: Commit.t()
  def staged(%__MODULE__{path: path}), do: Commit.staged(repo: path)

  @doc "Resolves a revision in the fixture repository."
  @spec sha(t(), String.t()) :: String.t()
  def sha(%__MODULE__{path: path}, rev) do
    {:ok, sha} = Git.rev_parse(path, rev)
    sha
  end

  @doc "Runs an arbitrary git command in the fixture repository, raising on failure."
  @spec git!(Path.t(), [String.t()], keyword()) :: binary()
  def git!(path, args, opts \\ []) do
    env =
      [
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"LC_ALL", "C"}
      ] ++ Keyword.get(opts, :env, [])

    case System.cmd("git", args, cd: path, env: env, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, status} -> raise "git #{Enum.join(args, " ")} exited #{status}: #{out}"
    end
  end

  # The directory containing the repository, used for scratch files that must not be committed.
  defp dir(%__MODULE__{path: path}), do: Path.dirname(path)
end
