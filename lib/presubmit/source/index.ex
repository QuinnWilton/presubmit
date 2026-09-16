defmodule Presubmit.Source.Index do
  @moduledoc """
  Tree-wide discovery of modules, for invariants that need to look beyond the
  files a commit changed: "some router routes this controller", "some
  supervisor starts this server", "a test module exists for this module".

  Every Elixir file matching the pattern is parsed once per tree object (see
  `Presubmit.Source.Facts`), so repeated discovery on the same revision is
  cheap.
  """

  alias Presubmit.{Pattern, Tree}
  alias Presubmit.Source.Facts
  alias Presubmit.Source.Facts.Module

  @doc "Every module defined in files of `tree` matching `pattern`."
  @spec modules(Tree.t(), Pattern.t()) :: [Module.t()]
  def modules(%Tree{} = tree, pattern \\ Presubmit.Paths.elixir_source()) do
    paths =
      tree
      |> Tree.paths()
      |> Enum.filter(&(Path.extname(&1) in [".ex", ".exs"] and Pattern.matches?(&1, pattern)))

    # Only paths not already in the facts cache need reading; fetch those in one go.
    tree = Tree.prefetch(tree, Enum.reject(paths, &Facts.cached?(tree, &1)))
    Enum.flat_map(paths, &Facts.extract!(tree, &1).modules)
  end

  @doc "The module named `name` in `tree`, if any file matching `pattern` defines it."
  @spec find(Tree.t(), module(), Pattern.t()) :: Module.t() | nil
  def find(%Tree{} = tree, name, pattern \\ Presubmit.Paths.elixir_source()) do
    tree |> modules(pattern) |> Enum.find(&(&1.name == name))
  end
end
