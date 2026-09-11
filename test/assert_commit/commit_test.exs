defmodule AssertCommit.CommitTest do
  use ExUnit.Case, async: true

  import AssertCommit.Assertions
  import AssertCommit.Query

  alias AssertCommit.{Commit, FileChange}

  describe "new/1 (synthetic change sets)" do
    test "classifies additions, deletions, and modifications" do
      commit =
        Commit.new(
          before: %{"keep" => "k\n", "gone" => "g\n", "edit" => "1\n"},
          after: %{"keep" => "k\n", "new" => "n\n", "edit" => "2\n"},
          message: "Subject"
        )

      assert Enum.map(commit.changes, &{&1.status, &1.path}) == [
               {:modified, "edit"},
               {:deleted, "gone"},
               {:added, "new"}
             ]

      assert added_lines(commit) == [{"edit", 1, "2"}, {"new", 1, "n"}]
      assert commit.source == :synthetic
    end

    test "declared renames are renames; undeclared moves are delete plus add" do
      before = %{"a" => "x\n"}
      after_files = %{"b" => "x\n"}

      assert [%FileChange{status: :renamed, old_path: "a", path: "b", additions: 0}] =
               Commit.new(before: before, after: after_files, renames: [{"a", "b"}]).changes

      assert [{:deleted, "a"}, {:added, "b"}] =
               Commit.new(before: before, after: after_files).changes
               |> Enum.map(&{&1.status, &1.path})
    end

    test "assertions work identically on synthetic commits" do
      commit =
        Commit.new(
          after: %{"lib/x.ex" => "defmodule X do\n  def f, do: IO.inspect(1)\nend\n"},
          message: "[x] add f"
        )

      assert modules_added(commit) == [X]
      assert public_api_diff(commit) == %{added: [{X, :f, 0}], removed: []}
      assert_scope_matches_paths(commit, ~r/^\[(\w+)\]/, fn scope -> ~r{^lib/#{scope}\.ex$} end)
      assert_raise ExUnit.AssertionError, fn -> refute_added_lines(commit, ~r/IO\.inspect/) end
      assert_raise ExUnit.AssertionError, fn -> assert_specs(commit) end
    end

    test "binary files get no hunks" do
      [change] = Commit.new(after: %{"img.png" => <<137, 80, 78, 71, 0, 1>>}).changes
      assert change.binary?
      assert change.hunks == []
    end
  end

  describe "Query.formatting_only?/1" do
    test "true for a whitespace-only edit" do
      assert formatting_only?(Commit.new(before: %{"a" => "x=1\n"}, after: %{"a" => "x = 1\n"}))
    end

    test "false when tokens change or files are added" do
      refute formatting_only?(Commit.new(before: %{"a" => "x=1\n"}, after: %{"a" => "x = 2\n"}))

      refute formatting_only?(
               Commit.new(before: %{"a" => "x=1\n"}, after: %{"a" => "x = 1\n", "b" => "\n"})
             )

      refute formatting_only?(Commit.new(before: %{}, after: %{}))
    end
  end
end
