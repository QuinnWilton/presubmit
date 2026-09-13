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

  # Runs an installed hook the way git would, from the repository root. Without `mix?` the PATH
  # has the base system tools and git but no mix — the scripts must decide before reaching mix.
  defp hook(repo, name, args, opts \\ []) do
    minimal =
      Enum.uniq(["/usr/bin", "/bin", Path.dirname(System.find_executable("git"))])
      |> Enum.join(":")

    path = if Keyword.get(opts, :mix?, false), do: System.get_env("PATH"), else: minimal

    {out, status} =
      System.cmd("sh", [Path.join(repo, ".git/hooks/#{name}") | args],
        cd: repo,
        env: [{"PATH", path}],
        stderr_to_stdout: true
      )

    {status, out}
  end

  defp flag(repo) do
    path = Path.join(repo, ".git/assert_commit_base")
    if File.exists?(path), do: {:flag, String.trim(File.read!(path))}, else: :none
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
             ~s|exec mix assert_commit --staged --base "$base" --message-file "$1" --repo "$root" --on-error warn|

    assert Hooks.installed(repo) == ["commit-msg", "prepare-commit-msg"]
    assert {:ok, ^paths} = Hooks.install(repo)
  end

  test "every hook that runs mix shares the guard preamble" do
    for hook <- ["commit-msg", "pre-commit"] do
      script = Hooks.script(hook, "apps/web")
      assert script =~ ~s|root="$(git rev-parse --show-toplevel)"|
      assert script =~ ~s|cd "$root/apps/web" \|\| exit 1|
      assert script =~ "MERGE_HEAD"
      assert script =~ "command -v mix"
      assert script =~ "--on-error warn"
    end

    refute Hooks.script("commit-msg", ".") =~ "cd "
    refute Hooks.script("prepare-commit-msg", "apps/web") =~ "exec mix"
  end

  test "installs a pre-commit hook on request", %{repo: repo} do
    assert {:ok, paths} = Hooks.install(repo, Hooks.default() ++ ["pre-commit"])
    assert "pre-commit" in Enum.map(paths, &Path.basename/1)

    assert File.read!(Path.join(repo, ".git/hooks/pre-commit")) =~
             ~s|exec mix assert_commit --staged --repo "$root" --on-error warn|
  end

  test "a subdirectory project gets hooks that cd into it", %{repo: repo} do
    project = Path.join(repo, "apps/web")
    File.mkdir_p!(project)
    assert {:ok, [_, commit_msg]} = Hooks.install(project)
    assert String.ends_with?(commit_msg, "/repo/.git/hooks/commit-msg")
    assert File.read!(commit_msg) =~ ~s|cd "$root/apps/web" \|\| exit 1|
    refute File.read!(Path.join(repo, ".git/hooks/prepare-commit-msg")) =~ "cd "
    assert Hooks.installed(project) == ["commit-msg", "prepare-commit-msg"]
  end

  test "refuses to install when core.hooksPath redirects hooks", %{repo: repo} do
    FixtureRepo.git!(repo, ["config", "core.hooksPath", "/elsewhere/hooks"])
    assert {:error, message} = Hooks.install(repo)
    assert message =~ "core.hooksPath is set to /elsewhere/hooks"
    refute File.exists?(Path.join(repo, ".git/hooks/commit-msg"))
  end

  test "refuses to overwrite a hook it did not install, and leaves it alone on uninstall", %{
    repo: repo
  } do
    foreign = Path.join(repo, ".git/hooks/commit-msg")
    File.mkdir_p!(Path.dirname(foreign))
    File.write!(foreign, "#!/bin/sh\necho theirs\n")

    assert {:error, message} = Hooks.install(repo)
    assert message =~ "already exists and was not installed by assert_commit"
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

  describe "the scripts" do
    setup %{repo: repo} do
      repo = %FixtureRepo{path: repo}
      repo = FixtureRepo.commit!(repo, message: "first", write: %{"a" => "1\n"})
      repo = FixtureRepo.commit!(repo, message: "second", write: %{"b" => "2\n"})
      {:ok, _} = Hooks.install(repo.path)
      File.write!(Path.join(repo.path, "msg"), "subject\n")

      %{
        repo: repo.path,
        head: FixtureRepo.sha(repo, "HEAD"),
        parent: FixtureRepo.sha(repo, "HEAD^")
      }
    end

    test "prepare-commit-msg records HEAD^ when amending HEAD and nothing otherwise", %{
      repo: repo,
      head: head,
      parent: parent
    } do
      assert {0, _} = hook(repo, "prepare-commit-msg", ["msg", "commit", head])
      assert flag(repo) == {:flag, parent}

      for args <- [["msg"], ["msg", "message"], ["msg", "template"], ["msg", "commit", parent]] do
        assert {0, _} = hook(repo, "prepare-commit-msg", args)
        assert flag(repo) == :none, "#{inspect(args)} should not record a base"
      end
    end

    test "prepare-commit-msg marks an amend of a root commit and of a merge commit", %{repo: repo} do
      Git.run!(repo, ["checkout", "-q", "--orphan", "solo"])
      Git.run!(repo, ["commit", "-q", "--allow-empty", "--no-verify", "-m", "root"])
      assert {0, _} = hook(repo, "prepare-commit-msg", ["msg", "commit", "HEAD"])
      assert flag(repo) == {:flag, "empty"}

      Git.run!(repo, ["checkout", "-q", "main"])

      Git.run!(repo, [
        "merge",
        "-q",
        "--no-ff",
        "--no-verify",
        "-m",
        "merge solo",
        "--allow-unrelated-histories",
        "solo"
      ])

      assert {0, _} = hook(repo, "prepare-commit-msg", ["msg", "commit", "HEAD"])
      assert flag(repo) == {:flag, "merge"}

      {0, out} = hook(repo, "commit-msg", ["msg"], mix?: true)
      assert out =~ "amending a merge commit; skipping"
      assert flag(repo) == :none
    end

    test "commit-msg and pre-commit skip while a merge is in progress", %{
      repo: repo,
      parent: parent
    } do
      {:ok, _} = Hooks.install(repo, Hooks.default() ++ ["pre-commit"])
      File.write!(Path.join(repo, ".git/MERGE_HEAD"), parent <> "\n")

      assert {0, out} = hook(repo, "commit-msg", ["msg"], mix?: true)
      assert out =~ "merge in progress; skipping"
      assert {0, out} = hook(repo, "pre-commit", [], mix?: true)
      assert out =~ "merge in progress; skipping"
    end

    test "commit-msg passes with a note when mix is not on PATH", %{repo: repo} do
      assert {0, out} = hook(repo, "commit-msg", ["msg"])
      assert out =~ "mix is not on PATH; skipping"
    end

    test "commit-msg reaches mix with --base after an amend", %{
      repo: repo,
      head: head,
      parent: parent
    } do
      # There is no mix.exs here, so mix fails; what matters is the command line it was given.
      assert {0, _} = hook(repo, "prepare-commit-msg", ["msg", "commit", head])
      {status, out} = hook(repo, "commit-msg", ["msg"], mix?: true)
      assert status != 0

      assert out =~ "could not find a Mix.Project" or out =~ "no mix.exs" or
               out =~ "assert_commit"

      assert flag(repo) == :none
      _ = parent
    end
  end
end
