defmodule Mix.Tasks.Presubmit.Install do
  @shortdoc "Installs git hooks that run mix presubmit on every commit"

  @moduledoc """
  Installs a `commit-msg` hook that runs `mix presubmit --staged
  --message-file "$1"`, so the staged changes and the message are checked
  together before the commit is created, and a `prepare-commit-msg` hook that
  tells it when the commit amends `HEAD`, so the amended commit (`HEAD^` to
  the index) is what gets checked rather than the delta since `HEAD`.

      mix presubmit.install                # prepare-commit-msg + commit-msg hooks
      mix presubmit.install --pre-commit   # also a pre-commit hook (content rules, before the editor opens)
      mix presubmit.install --uninstall    # remove the hooks this task installed

  Run it from the project directory (where `mix.exs` is); in a subdirectory
  project of a larger repository the hooks `cd` there before running. Hooks
  live in the repository's hooks directory, which is not versioned: each
  clone runs this once. A hook that was not installed by this task is never
  overwritten, and installation is refused when `core.hooksPath` is set.

  The hooks skip, with a note, while a merge is in progress, when amending a
  merge commit, and when `mix` is not on `PATH`; `git commit --no-verify`
  bypasses them entirely. Keep `mix presubmit` in CI as the backstop.
  """

  use Mix.Task

  alias Presubmit.Hooks

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [pre_commit: :boolean, uninstall: :boolean, repo: :string])

    repo = opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand()

    if Keyword.get(opts, :uninstall) do
      {:ok, removed} = Hooks.uninstall(repo)
      report("removed", removed)
    else
      hooks = Hooks.default() ++ if(Keyword.get(opts, :pre_commit), do: ["pre-commit"], else: [])

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
