defmodule AssertCommit.HooksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AssertCommit.{FixtureRepo, Git, Hooks}
  alias Mix.Tasks.AssertCommit.Install

  setup do
    dir =
      Path.join(System.tmp_dir!(), "assert_commit_hooks_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    %{repo: FixtureRepo.init!(dir).path}
  end

  test "installs executable prepare-commit-msg and commit-msg hooks by default, idempotently", %{
    repo: repo
  } do
    assert {:ok, paths} = Hooks.install(repo)
    assert Enum.map(paths, &Path.basename/1) == ["prepare-commit-msg", "commit-msg"]

    for path <- paths do
      assert Bitwise.band(File.stat!(path).mode, 0o111) != 0
      assert File.read!(path) =~ "# installed by mix assert_commit.install"
    end

    assert File.read!(Path.join(repo, ".git/hooks/commit-msg")) =~
             ~s|exec mix assert_commit --staged --base "$base" --message-file "$1"|

    assert Hooks.installed(repo) == ["commit-msg", "prepare-commit-msg"]
    assert {:ok, ^paths} = Hooks.install(repo)
  end

  test "installs a pre-commit hook on request", %{repo: repo} do
    assert {:ok, paths} = Hooks.install(repo, Hooks.default() ++ ["pre-commit"])
    assert "pre-commit" in Enum.map(paths, &Path.basename/1)

    assert File.read!(Path.join(repo, ".git/hooks/pre-commit")) =~
             "exec mix assert_commit --staged\n"
  end

  test "refuses to overwrite a hook it did not install, and leaves it alone on uninstall", %{
    repo: repo
  } do
    foreign = Path.join(repo, ".git/hooks/commit-msg")
    File.mkdir_p!(Path.dirname(foreign))
    File.write!(foreign, "#!/bin/sh\necho theirs\n")

    assert {:error, message} = Hooks.install(repo)
    assert message =~ "already exists and was not installed by assert_commit"
    assert message =~ ~s|AssertCommit.Hooks.script("commit-msg")|
    assert File.read!(foreign) =~ "theirs"
    refute File.exists?(Path.join(repo, ".git/hooks/prepare-commit-msg"))

    assert {:ok, []} = Hooks.uninstall(repo)
    assert File.exists?(foreign)
  end

  test "uninstall removes only its own hooks", %{repo: repo} do
    {:ok, _} = Hooks.install(repo, Hooks.default() ++ ["pre-commit"])
    assert {:ok, removed} = Hooks.uninstall(repo)
    assert length(removed) == 3
    assert Hooks.installed(repo) == []
  end

  test "the mix task reports what it did", %{repo: repo} do
    assert capture_io(fn -> Install.run(["--repo", repo]) end) =~ "installed "
    assert capture_io(fn -> Install.run(["--repo", repo, "--uninstall"]) end) =~ "removed "
    assert capture_io(fn -> Install.run(["--repo", repo, "--uninstall"]) end) =~ "nothing to do"
  end

  describe "the prepare-commit-msg script" do
    # Runs the installed script the way git would: (message file, source, sha).
    defp prepare(repo, args) do
      {out, status} =
        System.cmd("sh", [Path.join(repo, ".git/hooks/prepare-commit-msg") | args],
          cd: repo,
          stderr_to_stdout: true
        )

      assert status == 0, out
      flag = Path.join(repo, ".git/assert_commit_base")
      if File.exists?(flag), do: {:flag, String.trim(File.read!(flag))}, else: :none
    end

    setup %{repo: repo} do
      repo = %FixtureRepo{path: repo}
      repo = FixtureRepo.commit!(repo, message: "first", write: %{"a" => "1\n"})
      repo = FixtureRepo.commit!(repo, message: "second", write: %{"b" => "2\n"})
      {:ok, _} = Hooks.install(repo.path)

      %{
        repo: repo.path,
        head: FixtureRepo.sha(repo, "HEAD"),
        parent: FixtureRepo.sha(repo, "HEAD^")
      }
    end

    test "records HEAD^ when amending HEAD", %{repo: repo, head: head, parent: parent} do
      assert prepare(repo, ["msg", "commit", head]) == {:flag, parent}
      assert prepare(repo, ["msg", "commit", "HEAD"]) == {:flag, parent}
    end

    test "records nothing for an ordinary commit, a template, or reusing another commit's message",
         %{repo: repo, parent: parent} do
      assert prepare(repo, ["msg"]) == :none
      assert prepare(repo, ["msg", "message"]) == :none
      assert prepare(repo, ["msg", "template"]) == :none
      assert prepare(repo, ["msg", "commit", parent]) == :none
    end

    test "clears a stale flag from an aborted amend", %{repo: repo, head: head} do
      assert {:flag, _} = prepare(repo, ["msg", "commit", head])
      assert prepare(repo, ["msg"]) == :none
    end

    test "uses the empty tree when amending a root commit", %{repo: repo} do
      Git.run!(repo, ["checkout", "-q", "--orphan", "solo"])
      Git.run!(repo, ["commit", "-q", "--allow-empty", "--no-verify", "-m", "root"])
      assert prepare(repo, ["msg", "commit", "HEAD"]) == {:flag, Git.empty_tree(repo)}
    end
  end
end
