defmodule AssertCommit.HooksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AssertCommit.{FixtureRepo, Hooks}
  alias Mix.Tasks.AssertCommit.Install

  setup do
    dir =
      Path.join(System.tmp_dir!(), "assert_commit_hooks_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    %{repo: FixtureRepo.init!(dir).path}
  end

  test "installs an executable commit-msg hook by default, idempotently", %{repo: repo} do
    assert {:ok, [path]} = Hooks.install(repo)
    assert path == Path.join(repo, ".git/hooks/commit-msg")
    assert File.stat!(path).mode |> Bitwise.band(0o111) != 0
    assert File.read!(path) =~ ~s|exec mix assert_commit --staged --message-file "$1"|
    assert Hooks.installed(repo) == ["commit-msg"]

    assert {:ok, [^path]} = Hooks.install(repo)
  end

  test "installs a pre-commit hook on request", %{repo: repo} do
    assert {:ok, paths} = Hooks.install(repo, ["commit-msg", "pre-commit"])
    assert Enum.map(paths, &Path.basename/1) == ["commit-msg", "pre-commit"]

    assert File.read!(Path.join(repo, ".git/hooks/pre-commit")) =~
             "exec mix assert_commit --staged\n"

    assert Hooks.installed(repo) == ["commit-msg", "pre-commit"]
  end

  test "refuses to overwrite a hook it did not install, and leaves it alone on uninstall", %{
    repo: repo
  } do
    foreign = Path.join(repo, ".git/hooks/commit-msg")
    File.mkdir_p!(Path.dirname(foreign))
    File.write!(foreign, "#!/bin/sh\necho theirs\n")

    assert {:error, message} = Hooks.install(repo)
    assert message =~ "already exists and was not installed by assert_commit"
    assert message =~ ~s|--message-file "$1"|
    assert File.read!(foreign) =~ "theirs"

    assert {:ok, []} = Hooks.uninstall(repo)
    assert File.exists?(foreign)
  end

  test "uninstall removes only its own hooks", %{repo: repo} do
    {:ok, _} = Hooks.install(repo, ["commit-msg", "pre-commit"])
    assert {:ok, removed} = Hooks.uninstall(repo)
    assert length(removed) == 2
    assert Hooks.installed(repo) == []
    refute File.exists?(Path.join(repo, ".git/hooks/commit-msg"))
  end

  test "the mix task reports what it did", %{repo: repo} do
    assert capture_io(fn -> Install.run(["--repo", repo]) end) =~
             "installed "

    assert capture_io(fn ->
             Install.run(["--repo", repo, "--uninstall"])
           end) =~ "removed "

    assert capture_io(fn ->
             Install.run(["--repo", repo, "--uninstall"])
           end) =~ "nothing to do"
  end

  test "the installed commit-msg hook is what git would run", %{repo: repo} do
    {:ok, _} = Hooks.install(repo)

    hooks_dir =
      repo |> AssertCommit.Git.run!(["rev-parse", "--git-path", "hooks"]) |> String.trim()

    assert Path.expand(hooks_dir, repo) == Path.join(repo, ".git/hooks")
  end
end
