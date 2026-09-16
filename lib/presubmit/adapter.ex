defmodule Presubmit.Adapter do
  @moduledoc """
  Behaviour for library-aware adapters that turn a module's facts into a
  domain model: an Ecto schema's fields, a Phoenix router's routes, a
  supervisor's children.

  Adapters work purely on `Presubmit.Source.Facts.Module` — the module's
  `use`s and body AST — so they recognise *conventional shapes*, not macro
  semantics. Each adapter documents the shapes it understands.
  """

  alias Presubmit.Source.Facts.Module

  @doc "Whether this adapter has a model for the module."
  @callback recognize?(Module.t()) :: boolean()

  @doc "Extracts the model. Only called when `recognize?/1` returned true."
  @callback extract(Module.t()) :: struct()

  @doc "Extracts the model for `module` if the adapter recognises it."
  @spec model(module(), Module.t()) :: struct() | nil
  def model(adapter, %Module{} = module) do
    if adapter.recognize?(module), do: adapter.extract(module)
  end
end
