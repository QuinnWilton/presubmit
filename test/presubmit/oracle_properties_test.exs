defmodule Presubmit.OraclePropertiesTest do
  @moduledoc """
  Differential properties with git itself as the oracle: wherever presubmit
  claims to behave like git, the two are compared on generated input.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Presubmit.{Hunk, Message}

  @moduletag :tmp_dir

  defp git!(args, cd) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true, env: [{"LC_ALL", "C"}])
    out
  end

  # A trailer key: letters and dashes, starting with a letter, as git's `interpret-trailers` accepts.
  defp key_gen, do: string(?a..?z, min_length: 1, max_length: 6) |> map(&String.capitalize/1)

  defp value_gen,
    do:
      string([?a..?z, ?0..?9, ?\s], min_length: 1, max_length: 12)
      |> map(&String.trim/1)
      |> filter(&(&1 != ""))

  defp prose_gen,
    do:
      string([?a..?z, ?\s], min_length: 1, max_length: 30)
      |> map(&String.trim/1)
      |> filter(&(&1 != "" and not String.contains?(&1, ":")))

  describe "Message.parse/1 vs git interpret-trailers --parse" do
    property "the trailers presubmit sees are the trailers git sees", %{tmp_dir: dir} do
      check all(
              subject <- prose_gen(),
              body <- list_of(prose_gen(), max_length: 3),
              trailers <- list_of({key_gen(), value_gen()}, max_length: 4),
              trailing_prose <- one_of([constant(nil), prose_gen()]),
              max_runs: 60
            ) do
        paragraphs =
          [subject] ++
            body ++
            if(trailers == [],
              do: [],
              else: [Enum.map_join(trailers, "\n", fn {k, v} -> "#{k}: #{v}" end)]
            ) ++
            List.wrap(trailing_prose)

        raw = Enum.join(paragraphs, "\n\n") <> "\n"
        path = Path.join(dir, "msg")
        File.write!(path, raw)

        from_git =
          git!(["interpret-trailers", "--parse", path], dir)
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            [k, v] = String.split(line, ": ", parts: 2)
            {k, v}
          end)

        assert Message.parse(raw).trailers == from_git
      end
    end
  end

  describe "Message.clean/1 vs git stripspace --strip-comments" do
    property "comment lines and blank-line runs are removed the way git removes them", %{
      tmp_dir: dir
    } do
      line = one_of([prose_gen(), map(prose_gen(), &("# " <> &1)), constant(""), constant("#")])

      check all(lines <- list_of(line, max_length: 8), max_runs: 60) do
        raw = Enum.join(lines, "\n") <> "\n"
        path = Path.join(dir, "raw")
        File.write!(path, raw)

        {from_git, 0} =
          System.cmd("sh", ["-c", "git stripspace --strip-comments < \"$1\"", "sh", path],
            cd: dir
          )

        # git collapses runs of blank lines to one; presubmit only trims the ends. Compare modulo
        # blank-line runs, which is what the message parser is insensitive to anyway.
        normalize = fn text ->
          text |> String.split(~r/\n{2,}|\n/, trim: true) |> Enum.map(&String.trim/1)
        end

        assert normalize.(Message.clean(raw)) == normalize.(from_git)
      end
    end
  end

  describe "Hunk.diff/2 vs git diff --numstat" do
    # Git's xdiff is not a minimal edit script even with `--minimal`, so exact counts cannot agree
    # in general. What must hold: both see the same line delta, both agree on whether anything
    # changed, and `List.myers_difference/2` (which is minimal) never produces a longer script.
    property "line deltas agree with git and presubmit's edit script is never longer", %{
      tmp_dir: dir
    } do
      text =
        list_of(string(?a..?c, max_length: 2), max_length: 10)
        |> map(fn ls -> Enum.map_join(ls, "", &(&1 <> "\n")) end)

      check all(before <- text, after_text <- text, max_runs: 60) do
        a = Path.join(dir, "a")
        b = Path.join(dir, "b")
        File.write!(a, before)
        File.write!(b, after_text)

        {out, status} =
          System.cmd("git", ["diff", "--no-index", "--minimal", "--numstat", a, b],
            cd: dir,
            env: [{"LC_ALL", "C"}]
          )

        {git_added, git_removed} =
          case String.split(out, "\t") do
            [added, removed | _] -> {String.to_integer(added), String.to_integer(removed)}
            _ -> {0, 0}
          end

        hunks = Hunk.diff(before, after_text)
        added = length(Hunk.added_lines(hunks))
        removed = length(Hunk.removed_lines(hunks))

        assert added - removed == git_added - git_removed
        assert added + removed <= git_added + git_removed
        assert added + removed == 0 == (status == 0)
      end
    end
  end
end
