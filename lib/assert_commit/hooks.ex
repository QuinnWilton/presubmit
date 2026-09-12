defmodule AssertCommit.Hooks do
  @moduledoc """
  Installs and removes the git hooks that run `mix assert_commit`.

  The `commit-msg` hook checks the staged changes together with the message
  being written, so every rule runs before the commit exists. An optional
  `pre-commit` hook runs the content rules earlier, before the editor opens.
  Hooks written here carry a marker line; a hook without it belongs to
  something else and is never overwritten.
  """

  alias AssertCommit.Git

  @marker "# installed by mix assert_commit.install"

  @scripts %{
    "commit-msg" => """
    #!/bin/sh
    #{@marker}
    # Checks the staged changes together with the commit message.
    exec mix assert_commit --staged --message-file "$1"
    """,
    "pre-commit" => """
    #!/bin/sh
    #{@marker}
    # Checks the staged changes before the message is written.
    exec mix assert_commit --staged
    """
  }

  @type hook :: String.t()

  @doc "The hooks this module knows how to install."
  @spec hooks() :: [hook()]
  def hooks, do: Map.keys(@scripts) |> Enum.sort()

  @doc """
  Installs the named hooks into the repository's hooks directory.

  Returns the paths written, or `{:error, message}` if any target is a hook
  that was not installed by this module.
  """
  @spec install(Path.t(), [hook()]) :: {:ok, [Path.t()]} | {:error, String.t()}
  def install(repo, hooks \\ ["commit-msg"]) do
    dir = hooks_dir(repo)

    case Enum.find(hooks, &foreign?(Path.join(dir, &1))) do
      nil ->
        File.mkdir_p!(dir)

        paths =
          for hook <- hooks do
            path = Path.join(dir, hook)
            File.write!(path, Map.fetch!(@scripts, hook))
            File.chmod!(path, 0o755)
            path
          end

        {:ok, paths}

      hook ->
        {:error,
         "#{Path.join(dir, hook)} already exists and was not installed by assert_commit. " <>
           "Add `mix assert_commit --staged#{if hook == "commit-msg", do: " --message-file \"$1\"", else: ""}` to it, " <>
           "or move it aside and run this again."}
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
