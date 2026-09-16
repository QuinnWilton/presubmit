defmodule Presubmit.Hunk do
  @moduledoc """
  A contiguous run of changed lines within one file, with zero context.

  Line numbers on `:del` lines refer to the before-tree file; those on
  `:add` lines refer to the after-tree file, so an assertion can report
  `path:line` for the version of the file that will exist after the commit.
  """

  @enforce_keys [:old_start, :old_count, :new_start, :new_count, :lines]
  defstruct [:old_start, :old_count, :new_start, :new_count, :lines]

  @type line :: {:add | :del, pos_integer(), String.t()}

  @type t :: %__MODULE__{
          old_start: non_neg_integer(),
          old_count: non_neg_integer(),
          new_start: non_neg_integer(),
          new_count: non_neg_integer(),
          lines: [line()]
        }

  @doc """
  Computes hunks between two texts using a line-level Myers diff.

  Both inputs are split on `\\n`; a trailing newline does not produce an
  empty final line.
  """
  @spec diff(binary(), binary()) :: [t()]
  def diff(before, after_text) do
    old_lines = split_lines(before)
    new_lines = split_lines(after_text)

    old_lines
    |> List.myers_difference(new_lines)
    |> build_hunks(1, 1, [], [])
  end

  @doc """
  All added lines across `hunks`, in order.
  """
  @spec added_lines([t()]) :: [{pos_integer(), String.t()}]
  def added_lines(hunks) do
    for %__MODULE__{lines: lines} <- hunks, {:add, no, text} <- lines, do: {no, text}
  end

  @doc """
  All removed lines across `hunks`, in order.
  """
  @spec removed_lines([t()]) :: [{pos_integer(), String.t()}]
  def removed_lines(hunks) do
    for %__MODULE__{lines: lines} <- hunks, {:del, no, text} <- lines, do: {no, text}
  end

  defp split_lines(""), do: []

  # Only the final newline is a terminator; earlier ones delimit real (possibly empty) lines.
  defp split_lines(text) do
    text =
      if String.ends_with?(text, "\n"), do: binary_part(text, 0, byte_size(text) - 1), else: text

    String.split(text, "\n")
  end

  # Walks the edit script keeping before/after line counters. Consecutive
  # del/ins edits accumulate into the current hunk; an eq edit flushes it.
  defp build_hunks([], _old, _new, current, hunks) do
    Enum.reverse(flush(current, hunks))
  end

  defp build_hunks([{:eq, lines} | rest], old, new, current, hunks) do
    n = length(lines)
    build_hunks(rest, old + n, new + n, [], flush(current, hunks))
  end

  defp build_hunks([{:del, lines} | rest], old, new, current, hunks) do
    entries = lines |> Enum.with_index(old) |> Enum.map(fn {text, no} -> {:del, no, text} end)
    build_hunks(rest, old + length(lines), new, current ++ entries, hunks)
  end

  defp build_hunks([{:ins, lines} | rest], old, new, current, hunks) do
    entries = lines |> Enum.with_index(new) |> Enum.map(fn {text, no} -> {:add, no, text} end)
    build_hunks(rest, old, new + length(lines), current ++ entries, hunks)
  end

  defp flush([], hunks), do: hunks

  defp flush(lines, hunks) do
    dels = for {:del, no, _} <- lines, do: no
    adds = for {:add, no, _} <- lines, do: no

    hunk = %__MODULE__{
      old_start: List.first(dels) || 0,
      old_count: length(dels),
      new_start: List.first(adds) || 0,
      new_count: length(adds),
      lines: lines
    }

    [hunk | hunks]
  end
end
