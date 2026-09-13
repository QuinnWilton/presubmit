defmodule AssertCommit.Tree do
  @moduledoc """
  A snapshot of every file in the repository at one point in history.

  Trees are backed either by a git tree object or by an in-memory map of
  paths to contents. The rest of the library only ever calls `paths/1`,
  `exists?/2`, and `read/2`, so both backends behave identically.
  """

  alias AssertCommit.Git

  @enforce_keys [:paths, :reader, :oid]
  defstruct [:paths, :reader, :oid]

  @type t :: %__MODULE__{
          paths: MapSet.t(String.t()),
          reader: (String.t() -> {:ok, binary()} | :error),
          oid: String.t() | nil
        }

  @doc """
  Builds a tree from a git tree object.
  """
  @spec from_git(Path.t(), Git.oid()) :: t()
  def from_git(repo, oid) do
    # `ls-tree -r` also lists submodule entries (type `commit`); only blobs can be read.
    paths =
      for entry <- Git.run!(repo, ["ls-tree", "-r", "-z", oid]) |> String.split("\0", trim: true),
          [meta, path] <- [String.split(entry, "\t", parts: 2)],
          [_mode, "blob", _oid] <- [String.split(meta, " ")],
          do: path

    %__MODULE__{
      oid: oid,
      paths: MapSet.new(paths),
      reader: fn path -> Git.read_blob(repo, oid, path) end
    }
  end

  @doc """
  Builds an in-memory tree from a map of paths to file contents.
  """
  @spec from_map(%{optional(String.t()) => binary()}) :: t()
  def from_map(files) when is_map(files) do
    %__MODULE__{
      oid: nil,
      paths: files |> Map.keys() |> MapSet.new(),
      reader: fn path -> Map.fetch(files, path) end
    }
  end

  @doc """
  Every path in the tree, sorted.
  """
  @spec paths(t()) :: [String.t()]
  def paths(%__MODULE__{paths: paths}), do: Enum.sort(paths)

  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{paths: paths}, path), do: MapSet.member?(paths, path)

  @doc """
  Reads the file at `path`, or `:error` if it does not exist in this tree.
  """
  @spec read(t(), String.t()) :: {:ok, binary()} | :error
  def read(%__MODULE__{paths: paths, reader: reader}, path) do
    if MapSet.member?(paths, path), do: reader.(path), else: :error
  end

  @doc """
  Reads the file at `path`, raising if it does not exist.
  """
  @spec read!(t(), String.t()) :: binary()
  def read!(%__MODULE__{} = tree, path) do
    case read(tree, path) do
      {:ok, contents} -> contents
      :error -> raise ArgumentError, "#{path} does not exist in tree #{tree.oid || "(in-memory)"}"
    end
  end
end
