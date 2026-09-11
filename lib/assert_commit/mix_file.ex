defmodule AssertCommit.MixFile do
  @moduledoc """
  Reads dependency and version declarations from `mix.exs` and `mix.lock`
  without evaluating them.

  Recognised shapes: a `deps/0` function returning a list literal of
  `{:name, ...}` tuples, `@version "..."` or `version: "..."`, and the
  standard `%{"name" => {...}}` lockfile map.
  """

  alias AssertCommit.Tree

  @type dep :: %{name: atom(), requirement: String.t() | nil, opts: keyword()}

  @doc "Dependencies declared in `mix.exs`, or `[]` if absent or unparseable."
  @spec deps(Tree.t(), String.t()) :: [dep()]
  def deps(%Tree{} = tree, path \\ "mix.exs") do
    with {:ok, ast} <- parse(tree, path),
         {:ok, list} <- find_deps_list(ast) do
      Enum.flat_map(list, &dep/1)
    else
      _ -> []
    end
  end

  @doc "The project version from `mix.exs`, or nil."
  @spec version(Tree.t(), String.t()) :: String.t() | nil
  def version(%Tree{} = tree, path \\ "mix.exs") do
    with {:ok, ast} <- parse(tree, path) do
      {_, found} =
        Macro.prewalk(ast, nil, fn
          {:@, _, [{:version, _, [v]}]} = node, nil when is_binary(v) -> {node, v}
          {:version, v} = node, nil when is_binary(v) -> {node, v}
          node, acc -> {node, acc}
        end)

      found
    else
      _ -> nil
    end
  end

  @doc "Package names present in `mix.lock`, or `[]` if absent."
  @spec locked(Tree.t(), String.t()) :: [atom()]
  def locked(%Tree{} = tree, path \\ "mix.lock") do
    with {:ok, {:%{}, _, entries}} <- parse(tree, path) do
      for {name, _} <- entries, is_atom(name) or is_binary(name), do: to_atom(name)
    else
      _ -> []
    end
  end

  defp parse(tree, path) do
    with {:ok, source} <- Tree.read(tree, path) do
      Code.string_to_quoted(source, file: path, emit_warnings: false)
    end
  end

  defp find_deps_list(ast) do
    {_, found} =
      Macro.prewalk(ast, nil, fn
        {kind, _, [{:deps, _, _}, [do: body]]} = node, nil when kind in [:def, :defp] ->
          {node, last_expr(body)}

        node, acc ->
          {node, acc}
      end)

    case found do
      list when is_list(list) -> {:ok, list}
      _ -> :error
    end
  end

  defp last_expr({:__block__, _, items}), do: List.last(items)
  defp last_expr(expr), do: expr

  defp dep({name, req}) when is_atom(name) and is_binary(req),
    do: [%{name: name, requirement: req, opts: []}]

  defp dep({name, opts}) when is_atom(name) and is_list(opts),
    do: [%{name: name, requirement: nil, opts: literal_opts(opts)}]

  defp dep({:{}, _, [name, req, opts]}) when is_atom(name) and is_binary(req),
    do: [%{name: name, requirement: req, opts: literal_opts(opts)}]

  defp dep({:{}, _, [name, opts]}) when is_atom(name),
    do: [%{name: name, requirement: nil, opts: literal_opts(opts)}]

  defp dep(_), do: []

  defp literal_opts(opts) when is_list(opts),
    do: Enum.filter(opts, &match?({k, _} when is_atom(k), &1))

  defp literal_opts(_), do: []

  defp to_atom(name) when is_atom(name), do: name
  defp to_atom(name) when is_binary(name), do: String.to_atom(name)
end
