defmodule AssertCommit.FileChange do
  @moduledoc """
  One file's change between the before and after trees.

  `path` is always the path that is meaningful after the change: the new
  path for renames and copies, and the old path for deletions (so that
  `refute_removed/2` can match on it). `old_path` is set for renames and
  copies only.
  """

  alias AssertCommit.{Hunk, Tree}

  @enforce_keys [:status, :path]
  defstruct status: nil,
            path: nil,
            old_path: nil,
            similarity: nil,
            binary?: false,
            additions: 0,
            deletions: 0,
            hunks: []

  @type status :: :added | :modified | :deleted | :renamed | :copied | :type_changed

  @type t :: %__MODULE__{
          status: status(),
          path: String.t(),
          old_path: String.t() | nil,
          similarity: non_neg_integer() | nil,
          binary?: boolean(),
          additions: non_neg_integer(),
          deletions: non_neg_integer(),
          hunks: [Hunk.t()]
        }

  @doc """
  Builds a change record by diffing the file's contents in the two trees.

  Binary files (those containing a NUL byte, git's own heuristic) get no
  hunks and zero line counts.
  """
  @spec build(status(), String.t(), String.t() | nil, Tree.t(), Tree.t(), keyword()) :: t()
  def build(status, path, old_path, before, after_tree, opts \\ []) do
    before_path = old_path || path

    old_text = if status == :added, do: "", else: Tree.read!(before, before_path)
    new_text = if status == :deleted, do: "", else: Tree.read!(after_tree, path)

    base = %__MODULE__{
      status: status,
      path: path,
      old_path: old_path,
      similarity: Keyword.get(opts, :similarity)
    }

    if binary?(old_text) or binary?(new_text) do
      %{base | binary?: true}
    else
      hunks = Hunk.diff(old_text, new_text)

      %{
        base
        | hunks: hunks,
          additions: length(Hunk.added_lines(hunks)),
          deletions: length(Hunk.removed_lines(hunks))
      }
    end
  end

  @doc """
  The path of this file in the before tree, or `nil` for additions.
  """
  @spec before_path(t()) :: String.t() | nil
  def before_path(%__MODULE__{status: :added}), do: nil
  def before_path(%__MODULE__{old_path: nil, path: path}), do: path
  def before_path(%__MODULE__{old_path: old_path}), do: old_path

  @doc """
  The path of this file in the after tree, or `nil` for deletions.
  """
  @spec after_path(t()) :: String.t() | nil
  def after_path(%__MODULE__{status: :deleted}), do: nil
  def after_path(%__MODULE__{path: path}), do: path

  @spec binary?(binary()) :: boolean()
  defp binary?(text),
    do: text |> binary_part(0, min(byte_size(text), 8000)) |> String.contains?(<<0>>)
end
