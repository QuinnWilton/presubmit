defmodule Presubmit.HooksStateTest do
  @moduledoc """
  The prepare-commit-msg / commit-msg handshake as a state machine: random
  sequences of hook invocations and repository states are run through the
  installed scripts, and the recorded base, the command line `mix` receives,
  and whether the hook lets the commit through are compared with a model of
  the protocol.

  The fake `mix` plays every way a run can end: presubmit's verdict (`pass`,
  `fail`), presubmit 0.1.0's report without a verdict, and Mix or presubmit
  stopping before any rule ran, which must never block a commit.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Presubmit.{FixtureRepo, Git, Hooks}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    repo = FixtureRepo.init!(dir)
    repo = FixtureRepo.commit!(repo, message: "first", write: %{"a" => "1\n"})
    side = FixtureRepo.sha(repo, "HEAD")
    repo = FixtureRepo.commit!(repo, message: "second", write: %{"b" => "2\n"})
    {:ok, _} = Hooks.install(repo.path, Hooks.default() ++ ["pre-commit"])
    File.write!(Path.join(repo.path, "msg"), "subject\n")

    # A `mix` that records how it was called, then ends the way $MIX_MODE_FILE says.
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    fake = Path.join(bin, "mix")

    File.write!(fake, """
    #!/bin/sh
    printf '%s\\n' "$@" > "$MIX_ARGS_FILE"
    printf '%s' "$PRESUBMIT_VERDICT" > "$MIX_ARGS_FILE.verdict"
    case "$(cat "$MIX_MODE_FILE")" in
      pass) echo "Examining staged index"; echo pass > "$PRESUBMIT_VERDICT"; exit 0 ;;
      fail) echo "Examining staged index"; echo fail > "$PRESUBMIT_VERDICT"; exit 1 ;;
      legacy_pass) echo "Examining staged index"; exit 0 ;;
      legacy_fail) echo "Examining staged index"; exit 1 ;;
      deps) echo "Unchecked dependencies for environment dev:" >&2
            echo "** (Mix) Can't continue due to errors on dependencies" >&2; exit 1 ;;
      usage) echo "error: unknown arguments: --bogus"; exit 2 ;;
      silent) exit 1 ;;
    esac
    """)

    File.chmod!(fake, 0o755)

    path =
      Enum.uniq([bin, "/usr/bin", "/bin", Path.dirname(System.find_executable("git"))])
      |> Enum.join(":")

    %{
      repo: repo.path,
      side: side,
      start: FixtureRepo.sha(repo, "HEAD"),
      root: repo.path |> Git.run!(["rev-parse", "--show-toplevel"]) |> String.trim(),
      empty_tree: Git.empty_tree(repo.path),
      env: [
        {"PATH", path},
        {"MIX_ARGS_FILE", Path.join(dir, "mix_args")},
        {"MIX_MODE_FILE", Path.join(dir, "mix_mode")}
      ],
      args_file: Path.join(dir, "mix_args"),
      mode_file: Path.join(dir, "mix_mode")
    }
  end

  @modes [:pass, :fail, :legacy_pass, :legacy_fail, :deps, :usage, :silent]

  defp op_gen do
    one_of([
      tuple(
        {constant(:prepare),
         member_of([:none, :message, :template, :commit_head, :commit_parent])}
      ),
      constant(:commit_msg),
      constant(:pre_commit),
      tuple({constant(:mix), member_of(@modes)}),
      tuple({constant(:stale_verdict), member_of(["pass", "fail"])}),
      tuple({constant(:head), member_of([:root, :plain, :merge])}),
      tuple({constant(:merging), boolean()})
    ])
  end

  property "the recorded base and the mix command line follow the model", ctx do
    check all(ops <- list_of(op_gen(), min_length: 1, max_length: 10), max_runs: 40) do
      reset(ctx)
      model = %{head: :plain, flag: :none, merging: false, n: 0, mode: :pass}
      Enum.reduce(ops, model, &step(&1, &2, ctx))
    end
  end

  # The property reaches every outcome only with luck; the verdict table must hold every time.
  test "each way mix can end decides the commit the same way in both hooks", ctx do
    for mode <- @modes, stale <- [nil, "pass", "fail"], op <- [:commit_msg, :pre_commit] do
      reset(ctx)
      model = %{head: :plain, flag: :none, merging: false, n: 0, mode: :pass}
      model = step({:mix, mode}, model, ctx)
      model = if stale, do: step({:stale_verdict, stale}, model, ctx), else: model
      step(op, model, ctx)
    end
  end

  # Every run starts from the same repository state; ops that change HEAD are undone here.
  # HEAD is a symbolic ref, so `update-ref HEAD` moves the branch itself: reset to the SHA.
  defp reset(%{repo: repo, start: start, mode_file: mode_file}) do
    Git.run!(repo, ["update-ref", "HEAD", start])
    File.rm(Path.join(repo, ".git/MERGE_HEAD"))
    File.rm(Path.join(repo, ".git/presubmit_base"))
    File.rm_rf!(Path.join(repo, ".git/presubmit_run"))
    File.write!(mode_file, "pass")
  end

  defp step({:head, kind}, model, %{repo: repo, side: side} = _ctx) do
    tree = repo |> Git.run!(["rev-parse", "HEAD^{tree}"]) |> String.trim()
    n = model.n

    parents =
      case kind do
        :root -> []
        :plain -> ["-p", "HEAD"]
        :merge -> ["-p", "HEAD", "-p", side]
      end

    sha =
      repo
      |> Git.run!(["commit-tree", tree, "-m", "#{kind} #{n}"] ++ parents)
      |> String.trim()

    Git.run!(repo, ["update-ref", "HEAD", sha])
    %{model | head: kind, n: n + 1}
  end

  # MERGE_HEAD must name a real object: the hook asks git to verify it, not whether the file exists.
  defp step({:merging, on?}, model, %{repo: repo, side: side}) do
    path = Path.join(repo, ".git/MERGE_HEAD")
    if on?, do: File.write!(path, side <> "\n"), else: File.rm(path)
    %{model | merging: on?}
  end

  defp step({:mix, mode}, model, %{mode_file: mode_file}) do
    File.write!(mode_file, Atom.to_string(mode))
    %{model | mode: mode}
  end

  # Left behind by a hook that was killed: the next run must not read it as its own verdict.
  defp step({:stale_verdict, verdict}, model, %{repo: repo}) do
    File.mkdir_p!(Path.join(repo, ".git/presubmit_run"))
    File.write!(Path.join(repo, ".git/presubmit_run/verdict"), verdict <> "\n")
    model
  end

  defp step(:pre_commit, model, %{root: root} = ctx) do
    File.rm(ctx.args_file)
    {status, out} = hook(ctx, "pre-commit", [])

    if model.merging do
      assert {status, out =~ "merge in progress; skipping"} == {0, true}
      refute File.exists?(ctx.args_file)
    else
      assert_ran(ctx, model.mode, status, out, ["presubmit", "--staged", "--repo", root])
    end

    # pre-commit runs before prepare-commit-msg and never touches the recorded base.
    assert observed_flag(ctx.repo) == model.flag
    model
  end

  defp step({:prepare, source}, model, %{repo: repo} = ctx) do
    args =
      case source do
        :none -> ["msg"]
        :message -> ["msg", "message"]
        :template -> ["msg", "template"]
        :commit_head -> ["msg", "commit", "HEAD"]
        :commit_parent -> ["msg", "commit", "HEAD^"]
      end

    # Amending a root commit has no HEAD^ for git to resolve; the hook sees an unresolvable
    # SHA and records nothing, like any other non-amend.
    args = if source == :commit_parent and model.head == :root, do: ["msg"], else: args
    assert {0, _} = hook(ctx, "prepare-commit-msg", args)

    flag =
      case {source, model.head} do
        {:commit_head, :merge} -> :merge
        {:commit_head, :root} -> :empty
        {:commit_head, :plain} -> {:parent, sha(repo, "HEAD^")}
        _ -> :none
      end

    assert observed_flag(repo) == flag
    %{model | flag: flag}
  end

  defp step(:commit_msg, model, %{repo: repo, root: root, empty_tree: empty_tree} = ctx) do
    File.rm(ctx.args_file)
    {status, out} = hook(ctx, "commit-msg", ["msg"])

    expected_base =
      case model.flag do
        :none -> []
        :empty -> ["--base", empty_tree]
        {:parent, sha} -> ["--base", sha]
        :merge -> nil
      end

    cond do
      model.merging ->
        # The guard preamble runs before the flag is read, so the flag survives for the next
        # prepare-commit-msg to clear.
        assert {status, out =~ "merge in progress; skipping"} == {0, true}
        refute File.exists?(ctx.args_file)
        assert observed_flag(repo) == model.flag
        model

      is_nil(expected_base) ->
        assert {status, out =~ "amending a merge commit; skipping"} == {0, true}
        refute File.exists?(ctx.args_file)
        assert observed_flag(repo) == :none
        %{model | flag: :none}

      true ->
        assert_ran(
          ctx,
          model.mode,
          status,
          out,
          ["presubmit", "--staged"] ++ expected_base ++ ["--message-file", "msg", "--repo", root]
        )

        assert observed_flag(repo) == :none
        %{model | flag: :none}
    end
  end

  # The hook reached mix: it passed `argv` and a verdict file under the git directory, blocked
  # the commit exactly when presubmit ran and failed, quoted the error when presubmit did not
  # run, and cleaned up after itself.
  defp assert_ran(ctx, mode, status, out, argv) do
    assert String.split(File.read!(ctx.args_file), "\n", trim: true) ==
             argv ++ ["--on-error", "warn"]

    assert File.read!(ctx.args_file <> ".verdict") == ".git/presubmit_run/verdict"

    assert {status, could_not_run(out)} == expected(mode)
    refute File.exists?(Path.join(ctx.repo, ".git/presubmit_run"))
  end

  # {hook exit status, the reason quoted in "presubmit could not run: …", or nil}.
  defp expected(:pass), do: {0, nil}
  defp expected(:fail), do: {1, nil}
  defp expected(:legacy_pass), do: {0, nil}
  defp expected(:legacy_fail), do: {1, nil}
  defp expected(:deps), do: {0, "** (Mix) Can't continue due to errors on dependencies"}
  defp expected(:usage), do: {0, "error: unknown arguments: --bogus"}
  defp expected(:silent), do: {0, "mix exited with status 1"}

  defp could_not_run(out) do
    case Regex.run(~r/^presubmit could not run: (.*); commit allowed, CI still checks$/m, out) do
      [_, reason] -> reason
      nil -> nil
    end
  end

  defp hook(%{repo: repo, env: env}, name, args) do
    {out, status} =
      System.cmd("sh", [Path.join(repo, ".git/hooks/#{name}") | args],
        cd: repo,
        env: env,
        stderr_to_stdout: true
      )

    {status, out}
  end

  defp observed_flag(repo) do
    case File.read(Path.join(repo, ".git/presubmit_base")) do
      {:error, :enoent} -> :none
      {:ok, "merge\n"} -> :merge
      {:ok, "empty\n"} -> :empty
      {:ok, sha} -> {:parent, String.trim(sha)}
    end
  end

  defp sha(repo, rev), do: repo |> Git.run!(["rev-parse", rev]) |> String.trim()
end
