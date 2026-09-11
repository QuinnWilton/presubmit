defmodule AssertCommit.Source.Facts do
  @moduledoc """
  Structural facts about one Elixir source file, extracted from its AST.

  Facts are pure functions of the file's text: modules with their `use`s,
  attributes, functions, struct fields, and the modules they reference, with
  aliases resolved to full names. Nothing is compiled or evaluated, so facts
  can be extracted from any revision regardless of whether its dependencies
  are available.

  Facts for git-backed trees are memoised per `{tree_oid, path}` since a
  tree object never changes.
  """

  alias AssertCommit.Tree

  defmodule Function do
    @moduledoc "One function or macro, folded across its clauses."

    @enforce_keys [:module, :path, :name, :arity, :kind, :line]
    defstruct [
      :module,
      :path,
      :name,
      :arity,
      :kind,
      :line,
      spec?: false,
      doc: nil,
      deprecated?: false,
      impl?: false,
      clauses: []
    ]

    @type kind :: :def | :defp | :defmacro | :defmacrop

    @type t :: %__MODULE__{
            module: module(),
            path: String.t(),
            name: atom(),
            arity: arity(),
            kind: kind(),
            line: pos_integer(),
            spec?: boolean(),
            doc: nil | false | :present,
            deprecated?: boolean(),
            impl?: boolean(),
            clauses: [non_neg_integer()]
          }

    @doc "Whether the function is callable from other modules (`def` or `defmacro`)."
    @spec public?(t()) :: boolean()
    def public?(%__MODULE__{kind: kind}), do: kind in [:def, :defmacro]

    @doc """
    Whether the function is part of the module's documented API: public and
    not marked `@doc false`.
    """
    @spec api?(t()) :: boolean()
    def api?(%__MODULE__{doc: doc} = function), do: public?(function) and doc != false

    @doc "Identity used for diffing: `{module, name, arity}`."
    @spec key(t()) :: {module(), atom(), arity()}
    def key(%__MODULE__{module: m, name: n, arity: a}), do: {m, n, a}
  end

  defmodule Module do
    @moduledoc "One `defmodule`, including nested ones (named `Outer.Inner`)."

    @enforce_keys [:name, :path, :line, :body]
    defstruct [
      :name,
      :path,
      :line,
      :body,
      uses: [],
      behaviours: [],
      moduledoc: nil,
      functions: [],
      struct: nil,
      references: [],
      aliases: %{}
    ]

    @type t :: %__MODULE__{
            name: module(),
            path: String.t(),
            line: pos_integer(),
            body: Macro.t(),
            uses: [{module(), [Macro.t()]}],
            behaviours: [module()],
            moduledoc: nil | false | :present,
            functions: [Function.t()],
            struct: nil | %{fields: [atom()], enforce_keys: [atom()]},
            references: [module()],
            aliases: %{optional(atom()) => module()}
          }

    @doc "Whether the module `use`s `target`, optionally with a matching first argument."
    @spec uses?(t(), module(), term() | :any) :: boolean()
    def uses?(%__MODULE__{uses: uses}, target, arg \\ :any) do
      Enum.any?(uses, fn
        {^target, _} when arg == :any -> true
        {^target, [^arg | _]} -> true
        _ -> false
      end)
    end

    @doc "Public functions of the module."
    @spec public_functions(t()) :: [Function.t()]
    def public_functions(%__MODULE__{functions: functions}),
      do: Enum.filter(functions, &Function.public?/1)
  end

  @enforce_keys [:path, :modules]
  defstruct [:path, :modules]

  @type t :: %__MODULE__{path: String.t(), modules: [Module.t()]}

  @doc """
  Extracts facts for the file at `path` in `tree`.

  Returns `{:error, reason}` when the file is missing or does not parse.
  """
  @spec extract(Tree.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def extract(%Tree{oid: nil} = tree, path), do: do_extract(tree, path)

  def extract(%Tree{oid: oid} = tree, path) do
    key = {__MODULE__, oid, path}

    case :persistent_term.get(key, :miss) do
      :miss ->
        result = do_extract(tree, path)
        :persistent_term.put(key, result)
        result

      result ->
        result
    end
  end

  @doc "Extracts facts, returning an empty fact set for missing or unparseable files."
  @spec extract!(Tree.t(), String.t()) :: t()
  def extract!(tree, path) do
    case extract(tree, path) do
      {:ok, facts} -> facts
      {:error, _} -> %__MODULE__{path: path, modules: []}
    end
  end

  @doc "Extracts facts from source text directly (for tests and synthetic input)."
  @spec from_source(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def from_source(source, path \\ "nofile.ex") do
    with {:ok, ast} <- Code.string_to_quoted(source, file: path, columns: true) do
      modules = ast |> collect_modules(path, [], %{}) |> Enum.reverse()
      {:ok, %__MODULE__{path: path, modules: modules}}
    end
  end

  defp do_extract(tree, path) do
    with {:ok, source} <- read(tree, path) do
      from_source(source, path)
    end
  end

  defp read(tree, path) do
    case Tree.read(tree, path) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, :enoent}
    end
  end

  ## Module collection

  defp collect_modules(
         {:defmodule, meta, [{:__aliases__, _, parts}, [{:do, body}]]},
         path,
         prefix,
         env
       ) do
    full = prefix ++ parts
    name = Elixir.Module.concat(full)
    env = Map.put(env, :__MODULE__, name)
    {items, env} = body |> block_items() |> resolve_aliases(env)

    module = %Module{
      name: name,
      path: path,
      line: Keyword.get(meta, :line, 1),
      body: body,
      uses: uses(items, env),
      behaviours: behaviours(items, env),
      moduledoc: moduledoc(items),
      functions: functions(items, name, path),
      struct: struct_def(items),
      references: references(body, env, name),
      aliases: Map.delete(env, :__MODULE__)
    }

    nested =
      Enum.reduce(items, [], fn item, acc -> collect_modules(item, path, full, env) ++ acc end)

    nested ++ [module]
  end

  defp collect_modules({_, _, args}, path, prefix, env) when is_list(args) do
    Enum.reduce(args, [], fn arg, acc -> collect_modules(arg, path, prefix, env) ++ acc end)
  end

  defp collect_modules({a, b}, path, prefix, env) do
    collect_modules(b, path, prefix, env) ++ collect_modules(a, path, prefix, env)
  end

  defp collect_modules(list, path, prefix, env) when is_list(list) do
    Enum.reduce(list, [], fn item, acc -> collect_modules(item, path, prefix, env) ++ acc end)
  end

  defp collect_modules(_, _path, _prefix, _env), do: []

  defp block_items({:__block__, _, items}), do: items
  defp block_items(nil), do: []
  defp block_items(item), do: [item]

  ## Alias environment

  # Walks the module's top-level items in order, so an alias only affects what follows it.
  defp resolve_aliases(items, env) do
    Enum.reduce(items, {[], env}, fn item, {acc, env} ->
      {[item | acc], add_aliases(item, env)}
    end)
    |> then(fn {items, env} -> {Enum.reverse(items), env} end)
  end

  defp add_aliases({:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, children}]}, env) do
    Enum.reduce(children, env, fn {:__aliases__, _, parts}, env ->
      Map.put(env, List.last(parts), resolve(prefix ++ parts, env))
    end)
  end

  defp add_aliases({:alias, _, [{:__aliases__, _, parts}]}, env) do
    Map.put(env, List.last(parts), resolve(parts, env))
  end

  defp add_aliases({:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [as]}]]}, env) do
    Map.put(env, as, resolve(parts, env))
  end

  defp add_aliases(_, env), do: env

  @doc """
  Resolves alias parts to a full module name under `env`.

  `env` maps the first segment of an alias to the module it stands for, and
  `:__MODULE__` to the enclosing module.
  """
  @spec resolve([atom()], %{optional(atom()) => module()}) :: module()
  def resolve([{:__MODULE__, _, _} | rest], env),
    do: Elixir.Module.concat([Map.fetch!(env, :__MODULE__) | rest])

  def resolve([first | rest] = parts, env) do
    case Map.fetch(env, first) do
      {:ok, target} -> Elixir.Module.concat([target | rest])
      :error -> Elixir.Module.concat(parts)
    end
  end

  ## Attributes and directives

  defp uses(items, env) do
    for {:use, _, [{:__aliases__, _, parts} | args]} <- items, do: {resolve(parts, env), args}
  end

  defp behaviours(items, env) do
    for {:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]} <- items, do: resolve(parts, env)
  end

  defp moduledoc(items) do
    case Enum.find(items, &match?({:@, _, [{:moduledoc, _, [_]}]}, &1)) do
      {:@, _, [{:moduledoc, _, [false]}]} -> false
      {:@, _, [{:moduledoc, _, [_]}]} -> :present
      nil -> nil
    end
  end

  defp struct_def(items) do
    fields =
      Enum.find_value(items, fn
        {:defstruct, _, [fields]} -> struct_fields(fields)
        _ -> nil
      end)

    if fields do
      enforce =
        Enum.find_value(items, [], fn
          {:@, _, [{:enforce_keys, _, [keys]}]} -> List.wrap(keys)
          _ -> nil
        end)

      %{fields: fields, enforce_keys: enforce}
    end
  end

  defp struct_fields(fields) when is_list(fields) do
    Enum.map(fields, fn
      {name, _default} when is_atom(name) -> name
      name when is_atom(name) -> name
      _ -> :__dynamic__
    end)
  end

  defp struct_fields(_), do: [:__dynamic__]

  ## Functions

  # Pending @doc/@deprecated/@impl apply to the next function head. A @spec applies by name and
  # arity; a spec for the full arity of a head with defaults also covers the arities it generates.
  defp functions(items, module, path) do
    specs =
      for {:@, _, [{:spec, _, [spec]}]} <- items,
          head = spec_head(spec),
          do: head,
          into: MapSet.new()

    {functions, _pending} =
      Enum.reduce(items, {%{}, %{doc: nil, deprecated?: false, impl?: false}}, fn item,
                                                                                  {acc, pending} ->
        case item do
          {:@, _, [{:impl, _, [_]}]} ->
            {acc, %{pending | impl?: true}}

          {:@, _, [{:doc, _, [false]}]} ->
            {acc, %{pending | doc: false}}

          {:@, _, [{:doc, _, [_]}]} ->
            {acc, %{pending | doc: :present}}

          {:@, _, [{:deprecated, _, [_]}]} ->
            {acc, %{pending | deprecated?: true}}

          {kind, meta, [head | rest]} when kind in [:def, :defp, :defmacro, :defmacrop] ->
            {name, arities} = head_arities(head)
            clause_hash = :erlang.phash2(strip_meta({head, rest}))
            full_arity = Enum.max(arities)

            acc =
              Enum.reduce(arities, acc, fn arity, acc ->
                Map.update(
                  acc,
                  {name, arity},
                  %Function{
                    module: module,
                    path: path,
                    name: name,
                    arity: arity,
                    kind: kind,
                    line: Keyword.get(meta, :line, 0),
                    spec?:
                      MapSet.member?(specs, {name, arity}) or
                        MapSet.member?(specs, {name, full_arity}),
                    doc: pending.doc,
                    deprecated?: pending.deprecated?,
                    impl?: pending.impl?,
                    clauses: [clause_hash]
                  },
                  fn f -> %{f | clauses: f.clauses ++ [clause_hash]} end
                )
              end)

            {acc, %{doc: nil, deprecated?: false, impl?: false}}

          _ ->
            {acc, pending}
        end
      end)

    functions |> Map.values() |> Enum.sort_by(&{&1.line, &1.name, &1.arity})
  end

  defp head_arities({:when, _, [head, _guard]}), do: head_arities(head)

  defp head_arities({name, _, args}) when is_atom(name) do
    args = List.wrap(args)
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    n = length(args)
    {name, Enum.to_list((n - defaults)..n//1)}
  end

  defp spec_head({:when, _, [spec, _]}), do: spec_head(spec)

  defp spec_head({:"::", _, [{name, _, args}, _]}) when is_atom(name),
    do: {name, length(List.wrap(args))}

  defp spec_head(_), do: nil

  defp strip_meta(ast),
    do:
      Macro.prewalk(ast, fn
        {a, _meta, b} -> {a, [], b}
        other -> other
      end)

  ## References

  defp references(body, env, self) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, prefix}, :{}]}, _, children} = node, acc ->
          {node,
           Enum.map(children, fn {:__aliases__, _, parts} -> resolve(prefix ++ parts, env) end) ++
             acc}

        {:__aliases__, _, parts} = node, acc ->
          if Enum.all?(parts, &(is_atom(&1) or match?({:__MODULE__, _, _}, &1))),
            do: {node, [resolve(parts, env) | acc]},
            else: {node, acc}

        {:__MODULE__, _, ctx} = node, acc when is_atom(ctx) ->
          {node, [self | acc]}

        atom, acc when is_atom(atom) ->
          if module_atom?(atom), do: {atom, [atom | acc]}, else: {atom, acc}

        node, acc ->
          {node, acc}
      end)

    acc |> Enum.uniq() |> Enum.sort()
  end

  defp module_atom?(atom), do: atom |> Atom.to_string() |> String.starts_with?("Elixir.")
end
