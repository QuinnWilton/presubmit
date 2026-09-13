defmodule AssertCommit.Source do
  @moduledoc """
  Entry points for the Elixir-aware layers: the structural diff of a commit
  and the adapter models derived from it.

  - `diff/1` — modules and functions added, removed, renamed, changed.
  - `models/2` — an adapter's models for the modules a commit added,
    removed, or modified.
  - `find/3` — an adapter's models across a whole tree.
  """

  alias AssertCommit.{Adapter, Commit, Pattern, Tree}
  alias AssertCommit.Source.{Diff, Index}
  alias AssertCommit.Source.Facts.Module

  @typedoc "An adapter's models partitioned by what happened to their modules."
  @type model_diff :: %{added: [struct()], removed: [struct()], modified: [{struct(), struct()}]}

  @doc "The structural diff of the commit's Elixir source."
  @spec diff(Commit.t()) :: Diff.t()
  def diff(%Commit{elixir: %Diff{} = diff}), do: diff
  def diff(%Commit{} = commit), do: Diff.compute(commit)

  @doc """
  Models from `adapter` for modules the commit added, removed, or modified
  (renames count as modifications). Modules the adapter does not recognise
  are skipped; a module that stops or starts being recognised across the
  change shows up as removed or added respectively.
  """
  @spec models(Commit.t(), module()) :: model_diff()
  def models(%Commit{} = commit, adapter) do
    %Diff{modules: modules} = diff(commit)

    pairs = modules.modified ++ modules.renamed

    {modified, appeared, vanished} =
      Enum.reduce(pairs, {[], [], []}, fn {before, after_mod}, {mod, app, van} ->
        case {Adapter.model(adapter, before), Adapter.model(adapter, after_mod)} do
          {nil, nil} -> {mod, app, van}
          {nil, new} -> {mod, [new | app], van}
          {old, nil} -> {mod, app, [old | van]}
          {old, new} -> {[{old, new} | mod], app, van}
        end
      end)

    %{
      added: models_for(modules.added, adapter) ++ Enum.reverse(appeared),
      removed: models_for(modules.removed, adapter) ++ Enum.reverse(vanished),
      modified: Enum.reverse(modified)
    }
  end

  @doc "Every model `adapter` recognises among the modules of `tree` matching `pattern`."
  @spec find(Tree.t(), module(), Pattern.t()) :: [struct()]
  def find(%Tree{} = tree, adapter, pattern \\ AssertCommit.Paths.elixir_source()) do
    tree |> Index.modules(pattern) |> models_for(adapter)
  end

  defp models_for(modules, adapter) do
    for %Module{} = module <- modules, model = Adapter.model(adapter, module), do: model
  end
end
