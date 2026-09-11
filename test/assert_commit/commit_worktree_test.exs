defmodule AssertCommit.CommitWorktreeTest do
  use ExUnit.Case, async: true

  alias AssertCommit.{Commit, FixtureRepo, Fixtures, Git}

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
        Path.join(System.tmp_dir!(), "assert_commit_unborn_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(dir) end)
      repo = FixtureRepo.init!(dir)
      File.write!(Path.join(repo.path, "a.txt"), "a\n")

      assert [%{status: :added, path: "a.txt"}] =
               Commit.worktree(repo: repo.path).changes
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
