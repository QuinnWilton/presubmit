defmodule AssertCommit.Adapters.EctoSchema do
  @moduledoc """
  Models `use Ecto.Schema` modules.

  Recognised shapes: `schema "source" do ... end` and `embedded_schema do
  ... end` containing `field`, `belongs_to`, `has_one`, `has_many`,
  `many_to_many`, `embeds_one`, `embeds_many`, and `timestamps`.
  """

  @behaviour AssertCommit.Adapter

  alias AssertCommit.Source.Facts
  alias AssertCommit.Source.Facts.Module

  defmodule Field do
    @moduledoc "One `field`, association, or embed declaration."
    @enforce_keys [:name, :kind, :line]
    defstruct [:name, :kind, :type, :related, :line, opts: []]

    @type t :: %__MODULE__{
            name: atom(),
            kind:
              :field
              | :belongs_to
              | :has_one
              | :has_many
              | :many_to_many
              | :embeds_one
              | :embeds_many,
            type: term() | nil,
            related: module() | nil,
            line: pos_integer(),
            opts: keyword()
          }
  end

  @enforce_keys [:module, :source, :fields]
  defstruct [:module, :source, :fields, timestamps?: false]

  @type t :: %__MODULE__{
          module: module(),
          source: String.t() | nil,
          fields: [Field.t()],
          timestamps?: boolean()
        }

  @impl true
  def recognize?(%Module{} = module), do: Module.uses?(module, Ecto.Schema)

  @impl true
  def extract(%Module{} = module) do
    {source, block} =
      find_block(module.body, fn
        {:schema, _, [source, [do: block]]} when is_binary(source) -> {source, block}
        {:embedded_schema, _, [[do: block]]} -> {nil, block}
        _ -> nil
      end) || {nil, nil}

    items = if block, do: block_items(block), else: []

    %__MODULE__{
      module: module.name,
      source: source,
      fields: items |> Enum.flat_map(&field(&1, module)) |> Enum.sort_by(& &1.line),
      timestamps?: Enum.any?(items, &match?({:timestamps, _, _}, &1))
    }
  end

  @doc "Names of every field, association, and embed on the schema."
  @spec field_names(t()) :: [atom()]
  def field_names(%__MODULE__{fields: fields}), do: Enum.map(fields, & &1.name)

  @doc "Columns the schema's table is expected to have: plain fields and `belongs_to` foreign keys."
  @spec columns(t()) :: [atom()]
  def columns(%__MODULE__{fields: fields}) do
    Enum.flat_map(fields, fn
      %Field{kind: :field, name: name} ->
        [name]

      %Field{kind: :belongs_to, name: name, opts: opts} ->
        [Keyword.get(opts, :foreign_key, :"#{name}_id")]

      _ ->
        []
    end)
  end

  defp field({:field, meta, [name, type | rest]}, _module) when is_atom(name) do
    [
      %Field{
        name: name,
        kind: :field,
        type: type_literal(type),
        line: line(meta),
        opts: opts(rest)
      }
    ]
  end

  defp field({:field, meta, [name]}, _module) when is_atom(name) do
    [%Field{name: name, kind: :field, type: :string, line: line(meta)}]
  end

  defp field({kind, meta, [name, related | rest]}, module)
       when kind in [:belongs_to, :has_one, :has_many, :many_to_many, :embeds_one, :embeds_many] and
              is_atom(name) do
    [
      %Field{
        name: name,
        kind: kind,
        related: related_module(related, module),
        line: line(meta),
        opts: opts(rest)
      }
    ]
  end

  defp field(_, _), do: []

  defp related_module({:__aliases__, _, parts}, module),
    do: Facts.resolve(parts, Map.put(module.aliases, :__MODULE__, module.name))

  defp related_module(atom, _module) when is_atom(atom), do: atom
  defp related_module(_, _module), do: nil

  defp type_literal(atom) when is_atom(atom), do: atom
  defp type_literal({:array, inner}), do: {:array, type_literal(inner)}
  defp type_literal({:__aliases__, _, parts}), do: Elixir.Module.concat(parts)
  defp type_literal(other), do: Macro.to_string(other)

  defp opts([opts]) when is_list(opts), do: Enum.filter(opts, &match?({k, _} when is_atom(k), &1))
  defp opts(_), do: []

  defp line(meta), do: Keyword.get(meta, :line, 0)

  defp block_items({:__block__, _, items}), do: items
  defp block_items(nil), do: []
  defp block_items(item), do: [item]

  defp find_block(ast, fun) do
    {_, found} =
      Macro.prewalk(ast, nil, fn
        node, nil -> {node, fun.(node)}
        node, found -> {node, found}
      end)

    found
  end
end
