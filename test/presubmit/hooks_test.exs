defmodule Presubmit.HooksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Presubmit.Install
  alias Presubmit.{FixtureRepo, Git, Hooks}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "presubmit_hooks_#{System.unique_integer([:positive])}")

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
    path = Path.join(repo, ".git/presubmit_base")
    if File.exists?(path), do: {:flag, String.trim(File.read!(path))}, else: :none
  end

  test "installs executable prepare-commit-msg and commit-msg hooks by default, idempotently", %{
    repo: repo
  } do
    assert {:ok, paths} = Hooks.install(repo)
    assert Enum.map(paths, &Path.basename/1) == ["prepare-commit-msg", "commit-msg"]

    for path <- paths do
      assert Bitwise.band(File.stat!(path).mode, 0o111) != 0
      assert File.read!(path) =~ "# installed by mix presubmit.install"
    end

    commit_msg = File.read!(Path.join(repo, ".git/hooks/commit-msg"))
    assert commit_msg =~ ~s|presubmit --staged --base "$base" --message-file "$1"\n|

    assert commit_msg =~
             ~s|PRESUBMIT_VERDICT="$run/verdict" mix presubmit "$@" --repo "$root" --on-error warn $color|

    assert Hooks.installed(repo) == ["commit-msg", "prepare-commit-msg"]
    assert {:ok, ^paths} = Hooks.install(repo)
  end

  test "every hook that runs mix shares the guard preamble" do
    for hook <- ["commit-msg", "pre-commit"] do
      script = Hooks.script(hook, "apps/web")
      assert script =~ ~s|root="$(git rev-parse --show-toplevel)"|
      assert script =~ ~s|cd "$root/apps/web" 2>/dev/null \|\||
      assert script =~ "MERGE_HEAD"
      assert script =~ "command -v mix"
      assert script =~ "--on-error warn"
      assert script =~ "PRESUBMIT_VERDICT"
    end

    refute Hooks.script("commit-msg", ".") =~ "cd "
    refute Hooks.script("prepare-commit-msg", "apps/web") =~ "PRESUBMIT_VERDICT"
  end

  test "installs a pre-commit hook on request", %{repo: repo} do
    assert {:ok, paths} = Hooks.install(repo, Hooks.default() ++ ["pre-commit"])
    assert "pre-commit" in Enum.map(paths, &Path.basename/1)

    assert File.read!(Path.join(repo, ".git/hooks/pre-commit")) =~ ~r/^presubmit --staged$/m
  end

  test "a subdirectory project gets hooks that cd into it", %{repo: repo} do
    project = Path.join(repo, "apps/web")
    File.mkdir_p!(project)
    assert {:ok, [_, commit_msg]} = Hooks.install(project)
    assert String.ends_with?(commit_msg, "/repo/.git/hooks/commit-msg")
    assert File.read!(commit_msg) =~ ~s|cd "$root/apps/web" 2>/dev/null \|\||
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
    assert message =~ "already exists and was not installed by presubmit"
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

    test "commit-msg passes the empty tree as the base when amending a root commit", %{
      repo: repo
    } do
      Git.run!(repo, ["checkout", "-q", "--orphan", "solo"])
      Git.run!(repo, ["commit", "-q", "--allow-empty", "--no-verify", "-m", "root"])
      assert {0, _} = hook(repo, "prepare-commit-msg", ["msg", "commit", "HEAD"])

      # A `mix` that records its arguments, first on PATH.
      bin = Path.join(repo, ".git/fake_bin")
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "mix"), "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\n")
      File.chmod!(Path.join(bin, "mix"), 0o755)

      {_, 0} =
        System.cmd("sh", [Path.join(repo, ".git/hooks/commit-msg"), "msg"],
          cd: repo,
          env: [{"PATH", bin <> ":" <> System.get_env("PATH")}],
          stderr_to_stdout: true
        )

      args = File.read!(Path.join(bin, "mix.args")) |> String.split("\n", trim: true)
      assert ["presubmit", "--staged", "--base", base | _] = args
      assert base == Git.empty_tree(repo)
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

    test "commit-msg lets the commit through, quoting the error, when mix cannot run presubmit",
         %{repo: repo, head: head} do
      # There is no mix.exs here, so the real mix stops before presubmit exists: no verdict.
      assert {0, _} = hook(repo, "prepare-commit-msg", ["msg", "commit", head])
      {status, out} = hook(repo, "commit-msg", ["msg"], mix?: true)
      assert status == 0

      assert out =~
               ~r/^presubmit could not run: \*\* \(Mix\) .+; commit allowed, CI still checks$/m

      assert flag(repo) == :none
      refute File.exists?(Path.join(repo, ".git/presubmit_run"))
    end

    test "a subdirectory project that is gone lets the commit through", %{repo: repo} do
      File.mkdir_p!(Path.join(repo, "apps/web"))
      {:ok, _} = Hooks.install(Path.join(repo, "apps/web"))
      File.rm_rf!(Path.join(repo, "apps"))

      assert {0, out} = hook(repo, "commit-msg", ["msg"], mix?: true)

      assert out =~
               "presubmit could not run: no project at apps/web; commit allowed, CI still checks"
    end
  end
end
