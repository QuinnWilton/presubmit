defmodule Mix.Tasks.AssertCommit.Install do
  @shortdoc "Installs git hooks that run mix assert_commit on every commit"

  @moduledoc """
  Installs a `commit-msg` hook that runs `mix assert_commit --staged
  --message-file "$1"`, so the staged changes and the message are checked
  together before the commit is created.

      mix assert_commit.install                # commit-msg hook
      mix assert_commit.install --pre-commit   # also a pre-commit hook (content rules, before the editor opens)
      mix assert_commit.install --uninstall    # remove the hooks this task installed

  Hooks live in the repository's hooks directory (`.git/hooks` by default),
  which is not versioned: each clone runs this once. A hook that was not
  installed by this task is never overwritten. `git commit --no-verify`
  bypasses hooks, so keep `mix assert_commit --head` in CI.
  """

  use Mix.Task

  alias AssertCommit.Hooks

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [pre_commit: :boolean, uninstall: :boolean, repo: :string])

    repo = opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand()

    if Keyword.get(opts, :uninstall) do
      {:ok, removed} = Hooks.uninstall(repo)
      report("removed", removed)
    else
      hooks =
        if Keyword.get(opts, :pre_commit), do: ["commit-msg", "pre-commit"], else: ["commit-msg"]

      case Hooks.install(repo, hooks) do
        {:ok, paths} -> report("installed", paths)
        {:error, message} -> Mix.raise(message)
      end
    end
  end

  defp report(_verb, []), do: Mix.shell().info("nothing to do")

  defp report(verb, paths),
    do: Enum.each(paths, &Mix.shell().info("#{verb} #{Path.relative_to_cwd(&1)}"))
end
