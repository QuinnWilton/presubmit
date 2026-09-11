defmodule AssertCommit.Scenarios.SourcesTest do
  @moduledoc """
  Where a change set comes from: a commit, the staged index, every commit in
  a range, and the failure modes of each.
  """

  use ExUnit.Case, async: true

  import AssertCommit.Assertions
  import AssertCommit.Query

  alias AssertCommit.{Commit, FixtureRepo, Fixtures, Git}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{repo: %FixtureRepo{path: Fixtures.build!("shape", dir)}}
  end

  describe "the staged index" do
    test "is asserted on before a commit exists", %{repo: repo} do
      commit =
        repo
        |> FixtureRepo.stage!(write: %{"lib/shop/debug.ex" => "IO.inspect(:staged)\n"})
        |> FixtureRepo.staged()

      assert commit.source == :staged
      assert commit.sha == nil
      assert added(commit) == ["lib/shop/debug.ex"]

      assert_raise AssertCommit.Violation,
                   ~r/lib\/shop\/debug\.ex:1: IO\.inspect\(:staged\)/,
                   fn -> refute_added_lines(commit, ~r/IO\.inspect\(/) end
    end

    test "has no message, and says so", %{repo: repo} do
      commit = repo |> FixtureRepo.stage!(write: %{"x" => "x\n"}) |> FixtureRepo.staged()
      refute has_message?(commit)

      error = assert_raise AssertCommit.NoMessageError, fn -> assert_subject(commit, ~r/./) end
      assert Exception.message(error) =~ "built from :staged and has no commit message yet"
    end

    test "on an unborn branch diffs against the empty tree", %{tmp_dir: dir} do
      commit =
        dir
        |> Path.join("unborn")
        |> FixtureRepo.init!()
        |> FixtureRepo.stage!(write: %{"a" => "1\n"})
        |> FixtureRepo.staged()

      assert added(commit) == ["a"]
      assert before_paths(commit) == []
    end

    test "is empty when nothing is staged", %{repo: repo} do
      assert FixtureRepo.staged(repo).changes == []
    end
  end

  describe "a range of commits" do
    test "every commit in base..head is gated individually", %{repo: repo} do
      FixtureRepo.git!(repo.path, ["checkout", "-q", "-b", "feature", "main"])

      repo =
        repo
        |> FixtureRepo.commit!(
          message: "Document cart",
          write: %{"lib/shop/cart.ex" => "defmodule Shop.Cart do\n  @moduledoc \"Cart.\"\nend\n"}
        )
        |> FixtureRepo.commit!(
          message: "Move item",
          move: [{"lib/shop/cart/item.ex", "lib/shop/item.ex"}],
          write: %{
            "lib/shop/item.ex" =>
              "defmodule Shop.Item do\n  @moduledoc \"A line item.\"\n\n  defstruct [:price, :quantity]\n\n  @type t :: %__MODULE__{price: non_neg_integer(), quantity: pos_integer()}\nend\n"
          }
        )
        |> FixtureRepo.commit!(
          message: "Debug",
          write: %{"lib/shop/cart.ex" => "defmodule Shop.Cart do\n  IO.inspect(1)\nend\n"}
        )

      shas =
        repo.path
        |> Git.run!(["rev-list", "--reverse", "main..feature"])
        |> String.split("\n", trim: true)

      assert length(shas) == 3

      results =
        for sha <- shas do
          commit = Commit.rev(sha, repo: repo.path)

          try do
            assert_pure_move(commit)
            refute_added_lines(commit, ~r/IO\.inspect/)
            {subject(commit), :ok}
          rescue
            e in AssertCommit.Violation -> {subject(commit), e.message}
          end
        end

      assert [{"Document cart", :ok}, {"Move item", :ok}, {"Debug", message}] = results
      assert message =~ "lib/shop/cart.ex:2: IO.inspect(1)"
    end

    test "rev: accepts any revision syntax", %{repo: repo} do
      assert Commit.rev("scenario/pure_move~1", repo: repo.path).message.subject == "Base"
      assert Commit.rev("main", repo: repo.path).parents == []
    end
  end

  describe "a root commit" do
    test "diffs against the empty tree", %{repo: repo} do
      commit = Commit.rev("main", repo: repo.path)
      assert before_paths(commit) == []
      assert Enum.all?(commit.changes, &(&1.status == :added))
    end
  end

  describe "failure modes" do
    test "a merge commit is refused with an explanation", %{repo: repo} do
      FixtureRepo.git!(
        repo.path,
        ["merge", "-q", "--no-ff", "-m", "Merge pure_move", "scenario/pure_move"],
        env: [
          {"GIT_COMMITTER_DATE", "2026-01-03T00:00:00Z"},
          {"GIT_AUTHOR_DATE", "2026-01-03T00:00:00Z"}
        ]
      )

      error = assert_raise AssertCommit.MergeCommitError, fn -> FixtureRepo.head(repo) end
      assert Exception.message(error) =~ "is a merge commit with 2 parents"
      assert Exception.message(error) =~ "github.event.pull_request.head.sha"
    end

    test "a shallow clone is refused with the fetch-depth fix", %{repo: repo, tmp_dir: dir} do
      shallow = Path.join(dir, "shallow")

      FixtureRepo.git!(dir, [
        "clone",
        "-q",
        "--depth",
        "1",
        "--branch",
        "scenario/pure_move",
        "file://" <> repo.path,
        shallow
      ])

      error = assert_raise AssertCommit.ShallowCloneError, fn -> Commit.head(repo: shallow) end
      assert Exception.message(error) =~ "set `fetch-depth: 2`"
    end

    test "a repository with no commits raises a GitError naming the command", %{tmp_dir: dir} do
      repo = dir |> Path.join("empty") |> FixtureRepo.init!()
      error = assert_raise AssertCommit.GitError, fn -> Commit.head(repo: repo.path) end
      assert Exception.message(error) =~ ~r/^git log -1 .* failed in .* \(exit 128\)/
    end

    test "an unknown revision raises a GitError", %{repo: repo} do
      assert_raise AssertCommit.GitError, ~r/unknown revision|bad revision/, fn ->
        Commit.rev("nope", repo: repo.path)
      end
    end
  end
end
