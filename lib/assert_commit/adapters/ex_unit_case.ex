defmodule AssertCommit.Adapters.ExUnitCase do
  @moduledoc """
  Models test modules: `use ExUnit.Case`, or `use` of any module whose name
  ends in `Case` (`MyApp.DataCase`, `MyAppWeb.ConnCase`).

  The subject is inferred from the test module's name by stripping a `Test`
  suffix, which is how `mix test` and ExUnit's own conventions pair them.
  """

  @behaviour AssertCommit.Adapter

  alias AssertCommit.Source.Facts.Module

  @enforce_keys [:module, :subject, :tests]
  defstruct [:module, :subject, :tests, references: []]

  @type t :: %__MODULE__{
          module: module(),
          subject: module() | nil,
          tests: [String.t()],
          references: [module()]
        }

  @impl true
  def recognize?(%Module{uses: uses}) do
    Enum.any?(uses, fn {target, _} ->
      target == ExUnit.Case or String.ends_with?(Atom.to_string(target), "Case")
    end)
  end

  @impl true
  def extract(%Module{} = module) do
    tests =
      for {kind, _, [name | _]} <- block_items(module.body),
          kind in [:test, :property],
          is_binary(name),
          do: name

    %__MODULE__{
      module: module.name,
      subject: subject(module.name),
      tests: tests,
      references: module.references
    }
  end

  @doc "Whether the test module is about `subject`, by name or by reference."
  @spec covers?(t(), module()) :: boolean()
  def covers?(%__MODULE__{subject: subject, references: references}, module),
    do: subject == module or module in references

  defp subject(name) do
    case name |> Atom.to_string() |> String.replace_suffix("Test", "") do
      "" -> nil
      stripped -> String.to_atom(stripped)
    end
  end

  defp block_items({:__block__, _, items}), do: items
  defp block_items(nil), do: []
  defp block_items(item), do: [item]
end
