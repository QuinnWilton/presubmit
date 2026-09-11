defmodule AssertCommit.HunkTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AssertCommit.Hunk

  describe "diff/2" do
    test "identical texts produce no hunks" do
      assert Hunk.diff("a\nb\n", "a\nb\n") == []
    end

    test "an insertion carries after-tree line numbers" do
      assert [%Hunk{lines: [{:add, 2, "x"}], old_start: 0, new_start: 2}] =
               Hunk.diff("a\nb\n", "a\nx\nb\n")
    end

    test "a replacement pairs del and add in one hunk" do
      assert [%Hunk{lines: [{:del, 2, "b"}, {:add, 2, "B"}]}] =
               Hunk.diff("a\nb\nc\n", "a\nB\nc\n")
    end

    test "separate edits produce separate hunks" do
      assert [%Hunk{new_start: 1}, %Hunk{new_start: 4}] =
               Hunk.diff("a\nb\nc\nd\n", "A\nb\nc\nD\n")
    end

    test "an empty file to content is a single added hunk" do
      assert [%Hunk{old_count: 0, new_count: 2, lines: [{:add, 1, "a"}, {:add, 2, "b"}]}] =
               Hunk.diff("", "a\nb\n")
    end
  end

  describe "properties" do
    # Applying the edit script to the before text must reproduce the after text exactly.
    property "hunks reconstruct the after text from the before text" do
      line = string(?a..?c, max_length: 2)

      check all(
              old_lines <- list_of(line, max_length: 12),
              new_lines <- list_of(line, max_length: 12)
            ) do
        before = Enum.map_join(old_lines, "", &(&1 <> "\n"))
        after_text = Enum.map_join(new_lines, "", &(&1 <> "\n"))

        hunks = Hunk.diff(before, after_text)
        assert apply_hunks(old_lines, hunks) == new_lines

        for {no, text} <- Hunk.added_lines(hunks), do: assert(Enum.at(new_lines, no - 1) == text)

        for {no, text} <- Hunk.removed_lines(hunks),
            do: assert(Enum.at(old_lines, no - 1) == text)
      end
    end
  end

  defp apply_hunks(old_lines, hunks) do
    deleted = for h <- hunks, {:del, no, _} <- h.lines, into: MapSet.new(), do: no

    kept =
      old_lines
      |> Enum.with_index(1)
      |> Enum.reject(fn {_, no} -> MapSet.member?(deleted, no) end)
      |> Enum.map(&elem(&1, 0))

    added = for h <- hunks, {:add, no, text} <- h.lines, do: {no, text}

    Enum.reduce(added, kept, fn {no, text}, acc -> List.insert_at(acc, no - 1, text) end)
  end
end
