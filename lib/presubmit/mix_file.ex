defmodule Presubmit.MixFile do
  @moduledoc """
  Reads dependency and version declarations from `mix.exs` and `mix.lock`
  without evaluating them.

  Recognised shapes: a `deps/0` function returning a list literal of
  `{:name, ...}` tuples, `@version "..."` or `version: "..."`,
  `elixirc_paths:` (see `elixirc_paths/2`), and the standard
  `%{"name" => {...}}` lockfile map.
  """

  alias Presubmit.{Paths, Pattern, Tree}

  @type dep :: %{name: atom(), requirement: String.t() | nil, opts: keyword()}

  # Mix compiles `lib` when a project does not say otherwise.
  @default_elixirc_paths ["lib"]

  # Bounds the local calls followed while resolving `elixirc_paths:`, so a
  # recursive helper in `mix.exs` cannot loop.
  @max_call_depth 16

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

  @doc """
  The paths the project at `path` compiles Elixir from in the `:prod`
  environment, as written in its `mix.exs` (relative to the project).

  `:prod` is the environment a project is compiled in when it is somebody's
  dependency, so these are the paths of the code the package ships: test
  support and fixtures that `elixirc_paths(:test)` adds are excluded.

  `mix.exs` is read, not evaluated. The value of `elixirc_paths:` is
  resolved from literal lists of strings joined with `++`, `Mix.env()`,
  module attributes, `if` over comparisons of `Mix.env()`, and calls to
  functions defined in `mix.exs` whose clauses match on literals or
  variables, optionally with `==`, `!=`, `in`, `and`, `or`, or `not` guards.
  That covers the `elixirc_paths(Mix.env())` helper Phoenix's generator
  writes and the variations on it seen in practice.

  Returns `[]` for an umbrella root (`apps_path:`), which compiles nothing
  itself, and `["lib"]`, Mix's default, when `elixirc_paths:` is absent,
  when its value is beyond those shapes, or when `mix.exs` is missing or
  does not parse.
  """
  @spec elixirc_paths(Tree.t(), String.t()) :: [String.t()]
  def elixirc_paths(%Tree{} = tree, path \\ "mix.exs") do
    with {:ok, ast} <- parse(tree, path),
         {:ok, paths} <- resolve_elixirc_paths(ast) do
      paths
    else
      _ -> @default_elixirc_paths
    end
  end

  @doc """
  A pattern matching the Elixir files each project in the tree ships: the
  `.ex` files Mix compiles from the project's `elixirc_paths/2`, joined to
  the project's directory. These are the files a dependent compiles; test
  support and fixtures compiled only under `MIX_ENV=test` are not among
  them.

  Every `mix.exs` that `project_files/2` finds is a project, so umbrella
  apps and subdirectory projects each contribute their own paths. A tree
  with no `mix.exs` at all is not a Mix project; there the conventional
  `lib/` directories at any depth stand in.
  """
  @spec shipped_source(Tree.t()) :: Pattern.t()
  def shipped_source(%Tree{} = tree) do
    case project_files(tree, Paths.mix_files()) do
      [] ->
        Paths.lib_source()

      mix_files ->
        tree = Tree.prefetch(tree, mix_files)

        for mix_file <- mix_files,
            source_path <- elixirc_paths(tree, mix_file),
            pattern <- compiled_from(Path.dirname(mix_file), source_path),
            do: pattern
    end
  end

  # Mix compiles every `.ex` file under a directory in `elixirc_paths`, and
  # a path that names a file outright.
  defp compiled_from(project_dir, source_path) do
    case project_dir |> Path.join(source_path) |> Path.expand("/") do
      "/" -> [~r/\.ex$/]
      "/" <> relative -> [~r/^#{Regex.escape(relative)}\/.*\.ex$/, relative]
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

  @doc "Dependencies declared by every `mix.exs` in the tree (umbrella apps included), deduplicated by name."
  @spec all_deps(Tree.t()) :: [dep()]
  def all_deps(%Tree{} = tree) do
    paths = project_files(tree, Presubmit.Paths.mix_files())
    tree = Tree.prefetch(tree, paths)
    paths |> Enum.flat_map(&deps(tree, &1)) |> Enum.uniq_by(& &1.name)
  end

  @doc "Package names present in every `mix.lock` in the tree."
  @spec all_locked(Tree.t()) :: [atom()]
  def all_locked(%Tree{} = tree) do
    paths = project_files(tree, Presubmit.Paths.lock_files())
    tree = Tree.prefetch(tree, paths)
    paths |> Enum.flat_map(&locked(tree, &1)) |> Enum.uniq()
  end

  @doc """
  Paths in the tree matching `pattern`, excluding vendored dependencies and
  test fixtures (a `mix.exs` under `test/` describes a fixture project, not
  this one).
  """
  @spec project_files(Tree.t(), Regex.t()) :: [String.t()]
  def project_files(%Tree{} = tree, pattern) do
    tree
    |> Tree.paths()
    |> Enum.filter(fn path ->
      Regex.match?(pattern, path) and not Presubmit.Paths.vendored?(path) and
        not Regex.match?(Presubmit.Paths.test(), path)
    end)
  end

  defp parse(tree, path) do
    with {:ok, source} <- Tree.read(tree, path) do
      Code.string_to_quoted(source, file: path, emit_warnings: false)
    end
  end

  ## elixirc_paths

  defp resolve_elixirc_paths(ast) do
    case project_option(ast, :apps_path) do
      {:ok, _} ->
        {:ok, []}

      :error ->
        case project_option(ast, :elixirc_paths) do
          {:ok, expr} -> ast |> eval(expr, %{}, @max_call_depth) |> string_list()
          :error -> {:ok, @default_elixirc_paths}
        end
    end
  end

  defp string_list({:ok, list}) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: :error
  end

  defp string_list(_), do: :error

  # A keyword option is a two-element tuple in the AST; `defp elixirc_paths(...)`
  # is a three-element call, so the two never collide.
  defp project_option(ast, key) do
    {_, found} =
      Macro.prewalk(ast, :error, fn
        {^key, value} = node, :error -> {node, {:ok, value}}
        node, acc -> {node, acc}
      end)

    found
  end

  # Evaluates the small subset of Elixir that `elixirc_paths:` is written
  # in, with `Mix.env()` fixed to `:prod`. Anything else is `:error`, never
  # a guess.
  defp eval(_ast, _expr, _bindings, 0), do: :error

  defp eval(_ast, literal, _bindings, _depth)
       when is_binary(literal) or is_atom(literal) or is_number(literal),
       do: {:ok, literal}

  defp eval(ast, list, bindings, depth) when is_list(list),
    do: eval_all(ast, list, bindings, depth)

  defp eval(_ast, {{:., _, [{:__aliases__, _, [:Mix]}, :env]}, _, []}, _bindings, _depth),
    do: {:ok, :prod}

  defp eval(ast, {:__block__, _, [expr]}, bindings, depth), do: eval(ast, expr, bindings, depth)

  defp eval(ast, {:++, _, [left, right]}, bindings, depth) do
    with {:ok, l} when is_list(l) <- eval(ast, left, bindings, depth),
         {:ok, r} when is_list(r) <- eval(ast, right, bindings, depth),
         do: {:ok, l ++ r},
         else: (_ -> :error)
  end

  defp eval(ast, {op, _, [left, right]}, bindings, depth) when op in [:==, :!=, :in] do
    with {:ok, l} <- eval(ast, left, bindings, depth),
         {:ok, r} <- eval(ast, right, bindings, depth) do
      compare(op, l, r)
    end
  end

  defp eval(ast, {op, _, [left, right]}, bindings, depth) when op in [:and, :or] do
    with {:ok, l} when is_boolean(l) <- eval(ast, left, bindings, depth),
         {:ok, r} when is_boolean(r) <- eval(ast, right, bindings, depth),
         do: {:ok, if(op == :and, do: l and r, else: l or r)},
         else: (_ -> :error)
  end

  defp eval(ast, {op, _, [operand]}, bindings, depth) when op in [:not, :!] do
    case eval(ast, operand, bindings, depth) do
      {:ok, value} when is_boolean(value) -> {:ok, not value}
      _ -> :error
    end
  end

  defp eval(ast, {:if, _, [condition, branches]}, bindings, depth) when is_list(branches) do
    case eval(ast, condition, bindings, depth) do
      {:ok, true} -> eval(ast, Keyword.get(branches, :do), bindings, depth)
      {:ok, false} -> eval(ast, Keyword.get(branches, :else), bindings, depth)
      _ -> :error
    end
  end

  defp eval(ast, {:@, _, [{name, _, context}]}, bindings, depth) when is_atom(context) do
    case attribute(ast, name) do
      {:ok, expr} -> eval(ast, expr, bindings, depth - 1)
      :error -> :error
    end
  end

  # A bare name is a variable when a clause bound it, else a call without parentheses.
  defp eval(ast, {name, _, context}, bindings, depth) when is_atom(name) and is_atom(context) do
    case Map.fetch(bindings, name) do
      {:ok, value} -> {:ok, value}
      :error -> call(ast, name, [], depth)
    end
  end

  defp eval(ast, {name, _, args}, bindings, depth) when is_atom(name) and is_list(args) do
    with {:ok, values} <- eval_all(ast, args, bindings, depth),
         do: call(ast, name, values, depth)
  end

  defp eval(_ast, _expr, _bindings, _depth), do: :error

  defp eval_all(ast, exprs, bindings, depth) do
    Enum.reduce_while(exprs, {:ok, []}, fn expr, {:ok, acc} ->
      case eval(ast, expr, bindings, depth) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp compare(:==, l, r), do: {:ok, l == r}
  defp compare(:!=, l, r), do: {:ok, l != r}
  defp compare(:in, l, r) when is_list(r), do: {:ok, l in r}
  defp compare(:in, _l, _r), do: :error

  defp attribute(ast, name) do
    {_, found} =
      Macro.prewalk(ast, :error, fn
        {:@, _, [{^name, _, [value]}]} = node, :error -> {node, {:ok, value}}
        node, acc -> {node, acc}
      end)

    found
  end

  # Calls the first clause of the local function `name/arity` whose head
  # matches; a head or guard beyond the supported shapes stops resolution
  # rather than falling through to a later clause.
  defp call(ast, name, args, depth) do
    ast
    |> clauses(name, length(args))
    |> Enum.reduce_while(:error, fn {params, guard, body}, :error ->
      case bind(params, args, %{}) do
        {:ok, bindings} ->
          case guard_holds(ast, guard, bindings, depth) do
            {:ok, true} -> {:halt, eval(ast, body, bindings, depth - 1)}
            {:ok, false} -> {:cont, :error}
            :error -> {:halt, :error}
          end

        :no_match ->
          {:cont, :error}

        :error ->
          {:halt, :error}
      end
    end)
  end

  defp clauses(ast, name, arity) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, [{:do, body} | _]]} = node, acc when kind in [:def, :defp] ->
          case clause_head(head) do
            {^name, params, guard} when length(params) == arity ->
              {node, [{params, guard, body} | acc]}

            _ ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp clause_head({:when, _, [{name, _, params}, guard]}) when is_atom(name),
    do: {name, params || [], guard}

  defp clause_head({name, _, params}) when is_atom(name), do: {name, params || [], true}
  defp clause_head(_), do: :error

  defp guard_holds(_ast, true, _bindings, _depth), do: {:ok, true}

  defp guard_holds(ast, guard, bindings, depth) do
    case eval(ast, guard, bindings, depth) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp bind([], [], bindings), do: {:ok, bindings}

  defp bind([param | params], [arg | args], bindings) do
    case bind_one(param, arg, bindings) do
      {:ok, bindings} -> bind(params, args, bindings)
      other -> other
    end
  end

  defp bind_one(literal, arg, bindings)
       when is_atom(literal) or is_binary(literal) or is_number(literal) do
    if literal == arg, do: {:ok, bindings}, else: :no_match
  end

  defp bind_one({name, _, context}, arg, bindings) when is_atom(name) and is_atom(context) do
    if String.starts_with?(Atom.to_string(name), "_"),
      do: {:ok, bindings},
      else: {:ok, Map.put(bindings, name, arg)}
  end

  defp bind_one({:=, _, [left, right]}, arg, bindings) do
    with {:ok, bindings} <- bind_one(left, arg, bindings), do: bind_one(right, arg, bindings)
  end

  defp bind_one(_pattern, _arg, _bindings), do: :error

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
