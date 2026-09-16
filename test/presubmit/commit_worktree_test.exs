defmodule Presubmit.CommitWorktreeTest do
  use ExUnit.Case, async: true

  alias Presubmit.{Commit, FixtureRepo, Fixtures, Git}

  setup_all do: %{repo: Fixtures.repo("shape")}

  describe "Commit.worktree/1" do
    test "sees unstaged edits and untracked files, honours .gitignore, and leaves the index alone",
         %{repo: repo} do
      File.write!(
        Path.join(repo, "lib/shop/cart.ex"),
        "defmodule Shop.Cart do\n  def total(_), do: 0\nend\n"
      )

      File.write!(Path.join(repo, "lib/shop/new.ex"), "defmodule Shop.New do\nend\n")
      File.mkdir_p!(Path.join(repo, "_build"))
      File.write!(Path.join(repo, "_build/ignored.beam"), "x")

      on_exit(fn ->
        FixtureRepo.git!(repo, ["checkout", "-q", "--", "."]) &&
          File.rm_rf!(Path.join(repo, "lib/shop/new.ex"))
      end)

      commit = Commit.worktree(repo: repo)
      assert commit.source == :worktree
      assert commit.message == nil

      assert Enum.map(commit.changes, &{&1.status, &1.path}) == [
               {:modified, "lib/shop/cart.ex"},
               {:added, "lib/shop/new.ex"}
             ]

      assert Git.run!(repo, ["diff", "--cached", "--name-only"]) == ""
    end

    test "detects renames done on disk", %{repo: repo} do
      File.rename!(Path.join(repo, "lib/shop/cart/item.ex"), Path.join(repo, "lib/shop/item.ex"))

      on_exit(fn ->
        FixtureRepo.git!(repo, ["checkout", "-q", "--", "."]) &&
          File.rm_rf!(Path.join(repo, "lib/shop/item.ex"))
      end)

      assert [%{status: :renamed, old_path: "lib/shop/cart/item.ex", path: "lib/shop/item.ex"}] =
               Commit.worktree(repo: repo).changes
    end

    test "works on an unborn branch" do
      dir =
        Path.join(System.tmp_dir!(), "presubmit_unborn_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(dir) end)
      repo = FixtureRepo.init!(dir)
      File.write!(Path.join(repo.path, "a.txt"), "a\n")

      assert [%{status: :added, path: "a.txt"}] =
               Commit.worktree(repo: repo.path).changes
    end
  end

  describe "base:" do
    test "measures the index against another tree-ish, as an amend needs", %{repo: repo} do
      Git.run!(repo, ["checkout", "-q", "scenario/docs_only"])
      on_exit(fn -> Git.run!(repo, ["checkout", "-q", "main"]) end)
      File.write!(Path.join(repo, "extra.txt"), "x\n")
      Git.run!(repo, ["add", "extra.txt"])

      on_exit(fn ->
        Git.run!(repo, ["reset", "-q", "--", "extra.txt"]) &&
          File.rm(Path.join(repo, "extra.txt"))
      end)

      delta = Commit.staged(repo: repo)
      assert Enum.map(delta.changes, & &1.path) == ["extra.txt"]
      assert delta.base == nil

      amended = Commit.staged(repo: repo, base: "HEAD^")
      assert Enum.map(amended.changes, & &1.path) == ["extra.txt", "lib/shop/cart.ex"]
      assert amended.base == "HEAD^"
      assert Commit.worktree(repo: repo, base: "HEAD^").base == "HEAD^"
    end

    test "an unknown base is an error, not the empty tree", %{repo: repo} do
      assert_raise Presubmit.GitError, fn -> Commit.staged(repo: repo, base: "nope") end
    end
  end

  describe "Git.dirty?/1" do
    test "is false on a clean checkout and true for an untracked file", %{repo: repo} do
      refute Git.dirty?(repo)
      File.write!(Path.join(repo, "note.md"), "scratch\n")
      on_exit(fn -> File.rm(Path.join(repo, "note.md")) end)
      assert Git.dirty?(repo)
    end
  end
end

defmodule Presubmit.GitEnvTest do
  use ExUnit.Case, async: true

  alias Presubmit.{FixtureRepo, Git}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "presubmit_gitenv_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    %{repo: FixtureRepo.init!(dir).path}
  end

  test "the empty tree matches what git computes", %{repo: repo} do
    assert Git.empty_tree(repo) ==
             String.trim(FixtureRepo.git!(repo, ["hash-object", "-t", "tree", "/dev/null"]))
  end

  test "config/2 reads the repository's configuration, and nil when unset", %{repo: repo} do
    assert Git.config(repo, "user.name") == "Fixture"
    assert Git.config(repo, "assert.unset") == nil
  end

  test "plumbing output is unaffected by colour and signature display settings", %{repo: repo} do
    FixtureRepo.git!(repo, ["config", "color.ui", "always"])
    FixtureRepo.git!(repo, ["config", "log.showSignature", "true"])
    repo = FixtureRepo.commit!(%FixtureRepo{path: repo}, message: "one", write: %{"a" => "1\n"})
    repo = FixtureRepo.commit!(repo, message: "two", write: %{"a" => "2\n", "b" => "b\n"})

    commit = Presubmit.Commit.head(repo: repo.path)
    assert commit.message.subject == "two"
    assert Enum.map(commit.changes, &{&1.status, &1.path}) == [{:modified, "a"}, {:added, "b"}]
  end
end

defmodule Presubmit.TreePrefetchTest do
  use ExUnit.Case, async: true

  alias Presubmit.{Commit, Fixtures, Git, Tree}

  setup_all do: %{repo: Fixtures.repo("phoenix")}

  test "prefetched reads match per-file reads and unknown paths fall back", %{repo: repo} do
    commit = Commit.rev("scenario/routed_controller", repo: repo)
    tree = commit.after
    paths = Tree.paths(tree)

    fetched = Tree.prefetch(tree, paths ++ ["not/in/tree.ex"])
    assert fetched.oid == tree.oid and fetched.repo == repo

    for path <- paths, do: assert(Tree.read(fetched, path) == Tree.read(tree, path))
    assert Tree.read(fetched, "not/in/tree.ex") == :error
    assert Tree.prefetch(Tree.from_map(%{"a" => "1"}), ["a"]).repo == nil
  end

  test "archive/3 reads only the requested blobs", %{repo: repo} do
    {:ok, oid} = Git.rev_parse(repo, "main^{tree}")
    assert {:ok, blobs} = Git.archive(repo, oid, ["mix.exs", "lib/demo_web/router.ex"])
    assert Map.keys(blobs) |> Enum.sort() == ["lib/demo_web/router.ex", "mix.exs"]
    assert blobs["mix.exs"] =~ "defmodule Demo.MixProject"
    assert {:ok, %{}} = Git.archive(repo, oid, [])
  end
end
