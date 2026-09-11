defmodule AssertCommit.Adapters.EctoMigration do
  @moduledoc """
  Models `use Ecto.Migration` modules as a list of schema operations.

  Recognised shapes inside `change/0`, `up/0`, and `down/0`: `create table`,
  `create_if_not_exists table`, `alter table` (with `add`, `remove`,
  `modify`), `drop table`, `create index`/`create_if_not_exists index`
  (also `unique_index`), `drop index`, `rename`, and `execute`.
  """

  @behaviour AssertCommit.Adapter

  alias AssertCommit.Source.Facts.Module

  @typedoc "One schema operation. Table and index names are atoms or strings as written."
  @type op ::
          {:create_table, atom() | String.t(), [%{name: atom(), type: term(), opts: keyword()}]}
          | {:alter_table, atom() | String.t(),
             [
               {:add, atom(), term(), keyword()}
               | {:remove, atom()}
               | {:modify, atom(), term(), keyword()}
             ]}
          | {:drop_table, atom() | String.t()}
          | {:create_index, atom() | String.t(), [atom()], keyword()}
          | {:drop_index, atom() | String.t(), keyword()}
          | {:rename, term()}
          | {:execute, :reversible | :irreversible}

  @enforce_keys [:module, :path, :ops]
  defstruct [
    :module,
    :path,
    :version,
    ops: [],
    functions: [],
    disable_ddl_transaction?: false,
    disable_migration_lock?: false
  ]

  @type t :: %__MODULE__{
          module: module(),
          path: String.t(),
          version: String.t() | nil,
          ops: [{:change | :up | :down, op()}],
          functions: [:change | :up | :down],
          disable_ddl_transaction?: boolean(),
          disable_migration_lock?: boolean()
        }

  @impl true
  def recognize?(%Module{} = module), do: Module.uses?(module, Ecto.Migration)

  @impl true
  def extract(%Module{} = module) do
    items = block_items(module.body)

    functions =
      for {:def, _, [{name, _, _} | _]} <- items,
          name in [:change, :up, :down],
          uniq: true,
          do: name

    ops =
      for {:def, _, [{name, _, _}, [do: body]]} <- items,
          name in [:change, :up, :down],
          op <- ops(body),
          do: {name, op}

    %__MODULE__{
      module: module.name,
      path: module.path,
      version: version(module.path),
      ops: ops,
      functions: functions,
      disable_ddl_transaction?: attr?(items, :disable_ddl_transaction),
      disable_migration_lock?: attr?(items, :disable_migration_lock)
    }
  end

  @doc "The timestamp prefix of a migration filename, or nil."
  @spec version(String.t()) :: String.t() | nil
  def version(path) do
    case Regex.run(~r/^(\d{14})_/, Path.basename(path)) do
      [_, version] -> version
      nil -> nil
    end
  end

  @doc """
  Whether the migration can be rolled back: it defines `up` and `down`, or a
  `change` whose `execute` calls all carry a down statement.
  """
  @spec reversible?(t()) :: boolean()
  def reversible?(%__MODULE__{functions: functions, ops: ops}) do
    cond do
      :down in functions ->
        true

      :change in functions ->
        not Enum.any?(ops, &match?({:change, {:execute, :irreversible}}, &1))

      true ->
        false
    end
  end

  @doc "Columns added to `table` by this migration, from `create table` and `alter table ... add`."
  @spec columns_added(t(), atom() | String.t()) :: [atom()]
  def columns_added(%__MODULE__{ops: ops}, table) do
    for {fun, op} <- ops, fun in [:change, :up], column <- columns_in(op, table), do: column
  end

  defp columns_in({:create_table, t, columns}, table) do
    if same_table?(t, table), do: Enum.map(columns, & &1.name), else: []
  end

  defp columns_in({:alter_table, t, changes}, table) do
    if same_table?(t, table), do: for({:add, name, _, _} <- changes, do: name), else: []
  end

  defp columns_in(_, _), do: []

  defp same_table?(a, b), do: to_string(a) == to_string(b)

  defp ops(body) do
    body
    |> block_items()
    |> Enum.flat_map(fn
      {:create, _, [{:table, _, [name | _]}, [do: cols]]} ->
        [{:create_table, name, columns(cols)}]

      {:create_if_not_exists, _, [{:table, _, [name | _]}, [do: cols]]} ->
        [{:create_table, name, columns(cols)}]

      {:create, _, [{:table, _, [name | _]}]} ->
        [{:create_table, name, []}]

      {:alter, _, [{:table, _, [name | _]}, [do: changes]]} ->
        [{:alter_table, name, alterations(changes)}]

      {:drop, _, [{:table, _, [name | _]} | _]} ->
        [{:drop_table, name}]

      {:drop_if_exists, _, [{:table, _, [name | _]} | _]} ->
        [{:drop_table, name}]

      {create, _, [{index, _, [name, cols | rest]}]}
      when create in [:create, :create_if_not_exists] and index in [:index, :unique_index] ->
        opts = index_opts(rest)
        opts = if index == :unique_index, do: Keyword.put(opts, :unique, true), else: opts
        [{:create_index, name, List.wrap(cols), opts}]

      {drop, _, [{:index, _, [name | rest]} | _]} when drop in [:drop, :drop_if_exists] ->
        [{:drop_index, name, index_opts(rest)}]

      {:rename, _, args} ->
        [{:rename, Macro.to_string(args)}]

      {:execute, _, [_up, _down]} ->
        [{:execute, :reversible}]

      {:execute, _, [_]} ->
        [{:execute, :irreversible}]

      _ ->
        []
    end)
  end

  defp columns(cols) do
    for {:add, _, [name, type | rest]} <- block_items(cols),
        do: %{name: name, type: literal(type), opts: opts(rest)}
  end

  defp alterations(changes) do
    changes
    |> block_items()
    |> Enum.flat_map(fn
      {:add, _, [name, type | rest]} -> [{:add, name, literal(type), opts(rest)}]
      {:add_if_not_exists, _, [name, type | rest]} -> [{:add, name, literal(type), opts(rest)}]
      {:remove, _, [name | _]} -> [{:remove, name}]
      {:remove_if_exists, _, [name | _]} -> [{:remove, name}]
      {:modify, _, [name, type | rest]} -> [{:modify, name, literal(type), opts(rest)}]
      _ -> []
    end)
  end

  defp index_opts([opts]) when is_list(opts), do: opts(opts)
  defp index_opts(_), do: []

  defp opts([opts]) when is_list(opts), do: opts(opts)

  defp opts(opts) when is_list(opts),
    do:
      Enum.filter(
        opts,
        &match?({k, v} when is_atom(k) and (is_atom(v) or is_binary(v) or is_number(v)), &1)
      )

  defp opts(_), do: []

  defp literal(atom) when is_atom(atom), do: atom
  defp literal({:array, inner}), do: {:array, literal(inner)}
  defp literal(other), do: Macro.to_string(other)

  defp attr?(items, name), do: Enum.any?(items, &match?({:@, _, [{^name, _, [true]}]}, &1))

  defp block_items({:__block__, _, items}), do: items
  defp block_items(nil), do: []
  defp block_items(item), do: [item]
end
