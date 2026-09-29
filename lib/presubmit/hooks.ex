defmodule Presubmit.Hooks do
  @moduledoc """
  Installs and removes the git hooks that run `mix presubmit`.

  Two hooks work together so that the change set checked is the commit that
  is about to exist:

  - `prepare-commit-msg` learns from git whether the commit amends `HEAD`
    (source `commit` with `HEAD`'s SHA) and records `HEAD^` as the base in
    `.git/presubmit_base`, or removes that file otherwise.
  - `commit-msg` runs `mix presubmit --staged --message-file "$1"`, adding
    `--base <recorded>` when amending, so rules see `HEAD^ → index` — the
    amended commit — rather than the delta since `HEAD`, which could never
    satisfy a rule whose other half lives in the original commit.

  Git reports the message source as `message` rather than `commit` when
  `--amend` is combined with `-m` or `-F`, so that form of amend is not
  detected and the delta since `HEAD` is what gets checked; amend with the
  editor or `--no-edit`, or run `mix presubmit --staged --base HEAD^`.

  A hook blocks the commit only on presubmit's verdict. It points
  `PRESUBMIT_VERDICT` at a file under the git directory, and `mix presubmit`
  writes `pass` or `fail` there once its rules have run (`Presubmit.CLI`). When
  there is no verdict, presubmit did not run: Mix stopped first (stale or
  unresolvable dependencies, a project that does not load), or presubmit hit a
  configuration error or crashed. That is a fault in the checkout or the tool,
  not in the commit, so the hook prints `presubmit could not run: <the error>;
  commit allowed, CI still checks` and lets the commit through. Presubmit 0.1.0
  writes no verdict; its report (a line starting `Examining `) shows that it
  ran, and then its exit status is the verdict.

  The hooks also step aside, with a note, while a merge is in progress or
  when amending a merge commit (the change set would be someone else's
  branch), and when `mix` is not on `PATH` (GUI clients often lack the
  developer's shell environment). A rule that crashes is reported but does not
  block the commit (`--on-error warn`). CI remains the backstop for all of
  these.

  Hooks are installed for the project in the current directory; in a
  subdirectory project of a larger repository the scripts `cd` there first.
  A hook that was not installed by this module is never overwritten, and
  installation is refused when `core.hooksPath` points hooks elsewhere.
  """

  alias Presubmit.Git

  @marker "# installed by mix presubmit.install"

  @default ["prepare-commit-msg", "commit-msg"]

  @type hook :: String.t()

  @doc "The hooks this module knows how to install."
  @spec hooks() :: [hook()]
  def hooks, do: ["commit-msg", "pre-commit", "prepare-commit-msg"]

  @doc "The hooks installed by default: `prepare-commit-msg` and `commit-msg`."
  @spec default() :: [hook()]
  def default, do: @default

  @doc """
  The script installed for `hook`, for a project at `project_rel` relative
  to the repository root (`"."` for a root project).
  """
  @spec script(hook(), String.t()) :: String.t()
  def script(hook, project_rel \\ ".")

  def script("prepare-commit-msg", _project_rel) do
    """
    #!/bin/sh
    #{@marker}
    # Records the base for the commit-msg hook: HEAD^ when amending HEAD, nothing otherwise.
    flag="$(git rev-parse --git-path presubmit_base)"
    rm -f "$flag"
    if [ "$2" = "commit" ] && [ "$(git rev-parse --verify --quiet "$3")" = "$(git rev-parse --verify --quiet HEAD)" ]; then
      if git rev-parse --verify --quiet "HEAD^2" >/dev/null; then
        echo "merge" > "$flag"
      else
        git rev-parse --verify --quiet "HEAD^" > "$flag" || echo "empty" > "$flag"
      fi
    fi
    """
  end

  def script("commit-msg", project_rel) do
    """
    #!/bin/sh
    #{@marker}
    # Checks the staged changes together with the commit message; against HEAD^ when amending.
    #{preamble(project_rel)}
    flag="$(git rev-parse --git-path presubmit_base)"
    base=""
    if [ -f "$flag" ]; then
      base="$(cat "$flag")"
      rm -f "$flag"
    fi
    case "$base" in
      merge) echo "presubmit: amending a merge commit; skipping (CI checks the result)"; exit 0 ;;
      empty) base="$(#{empty_tree_sh()})" ;;
    esac
    if [ -n "$base" ]; then
      presubmit --staged --base "$base" --message-file "$1"
    fi
    presubmit --staged --message-file "$1"
    """
  end

  def script("pre-commit", project_rel) do
    """
    #!/bin/sh
    #{@marker}
    # Checks the staged changes before the message is written.
    #{preamble(project_rel)}
    presubmit --staged
    """
  end

  # Shared by the hooks that run mix: locate the project, step aside when a merge is in progress
  # or mix is unavailable, and define `presubmit`, which runs `mix presubmit` with the given
  # arguments and exits with its verdict.
  #
  # The output is teed so that the first error line can be quoted when there is no verdict;
  # `--color` keeps the report coloured through the pipe when the hook writes to a terminal.
  # Presubmit 0.1.0 writes no verdict, so a report ("Examining ...") stands in for one there.
  defp preamble(project_rel) do
    cd =
      if project_rel == ".",
        do: "",
        else:
          ~s|cd "$root/#{project_rel}" 2>/dev/null \|\| { echo "presubmit could not run: no project at #{project_rel}; commit allowed, CI still checks"; exit 0; }\n|

    """
    root="$(git rev-parse --show-toplevel)"
    #{cd}if git rev-parse --verify --quiet MERGE_HEAD >/dev/null; then
      echo "presubmit: merge in progress; skipping (CI checks the result)"
      exit 0
    fi
    if ! command -v mix >/dev/null 2>&1; then
      echo "presubmit: mix is not on PATH; skipping (CI checks the result)"
      exit 0
    fi
    # Blocks the commit only on presubmit's verdict; without one, presubmit did not run.
    presubmit() {
      run="$(git rev-parse --git-path presubmit_run)"
      rm -rf "$run"
      if ! mkdir -p "$run"; then
        echo "presubmit could not run: cannot create $run; commit allowed, CI still checks"
        exit 0
      fi
      trap 'rm -rf "$run"' EXIT
      color=""
      if [ -t 1 ]; then color="--color"; fi
      { PRESUBMIT_VERDICT="$run/verdict" mix presubmit "$@" --repo "$root" --on-error warn $color; echo "$?" > "$run/status"; } 2>&1 | tee "$run/log"
      case "$(cat "$run/verdict" 2>/dev/null)" in
        pass) exit 0 ;;
        fail) exit 1 ;;
      esac
      status="$(cat "$run/status" 2>/dev/null)"
      if [ "$status" = 0 ]; then exit 0; fi
      if grep -q '^Examining ' "$run/log"; then exit 1; fi
      reason="$(grep -E '^(\\*\\* |error: )' "$run/log" | head -n 1)"
      if [ -z "$reason" ]; then reason="$(grep -v '^[[:space:]]*$' "$run/log" | tail -n 1)"; fi
      echo "presubmit could not run: ${reason:-mix exited with status ${status:-unknown}}; commit allowed, CI still checks"
      exit 0
    }\
    """
  end

  # Inside `$(...)`, bash 3.2 (macOS's /bin/sh) takes an unparenthesised case pattern's `)` as
  # the end of the substitution; the POSIX `(pattern)` form parses everywhere.
  defp empty_tree_sh do
    ~s|case "$(git rev-parse --show-object-format)" in (sha256) echo 6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321 ;; (*) echo 4b825dc642cb6eb9a060e54bf8d69288fbee4904 ;; esac|
  end

  @doc """
  Installs the named hooks for the project at `project_dir` (the directory
  containing `mix.exs`), into its repository's hooks directory.

  Returns the paths written, or `{:error, message}` when `core.hooksPath`
  redirects hooks or a target is a hook that was not installed by this module.
  """
  @spec install(Path.t(), [hook()]) :: {:ok, [Path.t()]} | {:error, String.t()}
  def install(project_dir, hooks \\ @default) do
    project_dir = Path.expand(project_dir)
    root = toplevel(project_dir)
    rel = prefix(project_dir)
    dir = hooks_dir(root)

    cond do
      hooks_path = Git.config(root, "core.hooksPath") ->
        {:error,
         "core.hooksPath is set to #{hooks_path}, so git will not run hooks from #{dir}. " <>
           "Add the scripts from `Presubmit.Hooks.script/2` to the hooks there instead."}

      hook = Enum.find(hooks, &foreign?(Path.join(dir, &1))) ->
        {:error,
         "#{Path.join(dir, hook)} already exists and was not installed by presubmit. " <>
           "Move it aside and run this again, or merge the script from `Presubmit.Hooks.script(#{inspect(hook)})` into it."}

      true ->
        File.mkdir_p!(dir)

        paths =
          for hook <- hooks do
            path = Path.join(dir, hook)
            File.write!(path, script(hook, rel))
            File.chmod!(path, 0o755)
            path
          end

        {:ok, paths}
    end
  end

  @doc "Removes every hook this module installed. Foreign hooks are left alone."
  @spec uninstall(Path.t()) :: {:ok, [Path.t()]}
  def uninstall(project_dir) do
    dir = project_dir |> Path.expand() |> toplevel() |> hooks_dir()

    removed =
      for hook <- hooks(), path = Path.join(dir, hook), ours?(path) do
        File.rm!(path)
        path
      end

    {:ok, removed}
  end

  @doc "Which of the known hooks are currently installed by this module."
  @spec installed(Path.t()) :: [hook()]
  def installed(project_dir) do
    dir = project_dir |> Path.expand() |> toplevel() |> hooks_dir()
    Enum.filter(hooks(), &ours?(Path.join(dir, &1)))
  end

  defp toplevel(dir), do: dir |> Git.run!(["rev-parse", "--show-toplevel"]) |> String.trim()

  # The project's path relative to the repository root, as git sees it (symlinks and all).
  defp prefix(dir) do
    case dir
         |> Git.run!(["rev-parse", "--show-prefix"])
         |> String.trim()
         |> String.trim_trailing("/") do
      "" -> "."
      rel -> rel
    end
  end

  defp hooks_dir(root) do
    path = root |> Git.run!(["rev-parse", "--git-path", "hooks"]) |> String.trim()
    Path.expand(path, root)
  end

  defp ours?(path), do: File.regular?(path) and String.contains?(File.read!(path), @marker)
  defp foreign?(path), do: File.regular?(path) and not ours?(path)
end
