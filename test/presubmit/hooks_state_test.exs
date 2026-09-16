defmodule Presubmit.HooksStateTest do
  @moduledoc """
  The prepare-commit-msg / commit-msg handshake as a state machine: random
  sequences of hook invocations and repository states are run through the
  installed scripts, and the recorded base and the command line `mix`
  receives are compared with a model of the protocol.
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
    {:ok, _} = Hooks.install(repo.path)
    File.write!(Path.join(repo.path, "msg"), "subject\n")

    # A `mix` that only records how it was called.
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    fake = Path.join(bin, "mix")
    File.write!(fake, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$MIX_ARGS_FILE\"\n")
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
      env: [{"PATH", path}, {"MIX_ARGS_FILE", Path.join(dir, "mix_args")}],
      args_file: Path.join(dir, "mix_args")
    }
  end

  defp op_gen do
    one_of([
      tuple(
        {constant(:prepare),
         member_of([:none, :message, :template, :commit_head, :commit_parent])}
      ),
      constant(:commit_msg),
      tuple({constant(:head), member_of([:root, :plain, :merge])}),
      tuple({constant(:merging), boolean()})
    ])
  end

  property "the recorded base and the mix command line follow the model", ctx do
    check all(ops <- list_of(op_gen(), min_length: 1, max_length: 8), max_runs: 25) do
      reset(ctx)
      model = %{head: :plain, flag: :none, merging: false, n: 0}
      Enum.reduce(ops, model, &step(&1, &2, ctx))
    end
  end

  # Every run starts from the same repository state; ops that change HEAD are undone here.
  # HEAD is a symbolic ref, so `update-ref HEAD` moves the branch itself: reset to the SHA.
  defp reset(%{repo: repo, start: start}) do
    Git.run!(repo, ["update-ref", "HEAD", start])
    File.rm(Path.join(repo, ".git/MERGE_HEAD"))
    File.rm(Path.join(repo, ".git/presubmit_base"))
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
        assert status == 0

        assert String.split(File.read!(ctx.args_file), "\n", trim: true) ==
                 ["presubmit", "--staged"] ++
                   expected_base ++
                   ["--message-file", "msg", "--repo", root, "--on-error", "warn"]

        assert observed_flag(repo) == :none
        %{model | flag: :none}
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
