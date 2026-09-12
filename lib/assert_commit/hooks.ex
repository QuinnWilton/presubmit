defmodule AssertCommit.Hooks do
  @moduledoc """
  Installs and removes the git hooks that run `mix assert_commit`.

  Two hooks work together so that the change set checked is the commit that
  is about to exist:

  - `prepare-commit-msg` learns from git whether the commit amends `HEAD`
    (source `commit` with `HEAD`'s SHA) and records `HEAD^` as the base in
    `.git/assert_commit_base`, or removes that file otherwise.
  - `commit-msg` runs `mix assert_commit --staged --message-file "$1"`, adding
    `--base <recorded>` when amending, so rules see `HEAD^ → index` — the
    amended commit — rather than the delta since `HEAD`, which could never
    satisfy a rule whose other half lives in the original commit.

  An optional `pre-commit` hook runs the content rules earlier, before the
  editor opens. Hooks written here carry a marker line; a hook without it
  belongs to something else and is never overwritten.
  """

  alias AssertCommit.Git

  @marker "# installed by mix assert_commit.install"

  @scripts %{
    "prepare-commit-msg" => """
    #!/bin/sh
    #{@marker}
    # Records the base for the commit-msg hook: HEAD^ when amending HEAD, nothing otherwise.
    flag="$(git rev-parse --git-path assert_commit_base)"
    rm -f "$flag"
    if [ "$2" = "commit" ] && [ "$(git rev-parse --verify --quiet "$3")" = "$(git rev-parse --verify --quiet HEAD)" ]; then
      git rev-parse --verify --quiet "HEAD^" > "$flag" || git hash-object -t tree /dev/null > "$flag"
    fi
    """,
    "commit-msg" => """
    #!/bin/sh
    #{@marker}
    # Checks the staged changes together with the commit message; against HEAD^ when amending.
    flag="$(git rev-parse --git-path assert_commit_base)"
    if [ -f "$flag" ]; then
      base="$(cat "$flag")"
      rm -f "$flag"
      exec mix assert_commit --staged --base "$base" --message-file "$1"
    fi
    exec mix assert_commit --staged --message-file "$1"
    """,
    "pre-commit" => """
    #!/bin/sh
    #{@marker}
    # Checks the staged changes before the message is written.
    exec mix assert_commit --staged
    """
  }

  @default ["prepare-commit-msg", "commit-msg"]

  @type hook :: String.t()

  @doc "The hooks this module knows how to install."
  @spec hooks() :: [hook()]
  def hooks, do: Map.keys(@scripts) |> Enum.sort()

  @doc "The hooks installed by default: `prepare-commit-msg` and `commit-msg`."
  @spec default() :: [hook()]
  def default, do: @default

  @doc "The script installed for `hook`."
  @spec script(hook()) :: String.t()
  def script(hook), do: Map.fetch!(@scripts, hook)

  @doc """
  Installs the named hooks into the repository's hooks directory.

  Returns the paths written, or `{:error, message}` if any target is a hook
  that was not installed by this module.
  """
  @spec install(Path.t(), [hook()]) :: {:ok, [Path.t()]} | {:error, String.t()}
  def install(repo, hooks \\ @default) do
    dir = hooks_dir(repo)

    case Enum.find(hooks, &foreign?(Path.join(dir, &1))) do
      nil ->
        File.mkdir_p!(dir)

        paths =
          for hook <- hooks do
            path = Path.join(dir, hook)
            File.write!(path, script(hook))
            File.chmod!(path, 0o755)
            path
          end

        {:ok, paths}

      hook ->
        {:error,
         "#{Path.join(dir, hook)} already exists and was not installed by assert_commit. " <>
           "Move it aside and run this again, or merge the script from `AssertCommit.Hooks.script(#{inspect(hook)})` into it."}
    end
  end

  @doc "Removes every hook this module installed. Foreign hooks are left alone."
  @spec uninstall(Path.t()) :: {:ok, [Path.t()]}
  def uninstall(repo) do
    dir = hooks_dir(repo)

    removed =
      for hook <- hooks(), path = Path.join(dir, hook), ours?(path) do
        File.rm!(path)
        path
      end

    {:ok, removed}
  end

  @doc "Which of the known hooks are currently installed by this module."
  @spec installed(Path.t()) :: [hook()]
  def installed(repo) do
    dir = hooks_dir(repo)
    Enum.filter(hooks(), &ours?(Path.join(dir, &1)))
  end

  defp hooks_dir(repo) do
    path = repo |> Git.run!(["rev-parse", "--git-path", "hooks"]) |> String.trim()
    Path.expand(path, repo)
  end

  defp ours?(path), do: File.regular?(path) and String.contains?(File.read!(path), @marker)
  defp foreign?(path), do: File.regular?(path) and not ours?(path)
end
