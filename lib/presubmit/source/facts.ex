defmodule Presubmit.Source.Facts do
  @moduledoc """
  Structural facts about one Elixir source file, extracted from its AST.

  Facts are pure functions of the file's text: modules with their `use`s,
  attributes, functions, struct fields, and the modules they reference, with
  aliases resolved to full names. Nothing is compiled or evaluated, so facts
  can be extracted from any revision regardless of whether its dependencies
  are available.

  Facts for git-backed trees are memoised by blob object id and path, in an
  ETS table shared by every process: facts are a pure function of a file's
  contents and its path, so a range of commits parses each distinct version
  of a file exactly once.
  The table is bounded (cleared when it exceeds 50 000 entries) and can be
  emptied with `clear_cache/0`.
  """

  alias Presubmit.Tree

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
      delegate?: false,
      module_hidden?: false,
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
            delegate?: boolean(),
            module_hidden?: boolean(),
            clauses: [non_neg_integer()]
          }

    @doc "Whether the function is callable from other modules (`def` or `defmacro`)."
    @spec public?(t()) :: boolean()
    def public?(%__MODULE__{kind: kind}), do: kind in [:def, :defmacro]

    @doc """
    Whether the function is part of the module's documented API: public, not
    marked `@doc false`, and not in a module marked `@moduledoc false`.
    """
    @spec api?(t()) :: boolean()
    def api?(%__MODULE__{doc: doc, module_hidden?: hidden?} = function),
      do: public?(function) and doc != false and not hidden?

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
  @cache :presubmit_facts
  @cache_limit 50_000

  @spec extract(Tree.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def extract(%Tree{} = tree, path) do
    case Tree.blob(tree, path) do
      nil ->
        do_extract(tree, path)

      blob ->
        # Facts carry the path (modules, functions, migration versions), so identical blobs at
        # different paths are different facts.
        case cache_get({blob, path}) do
          {:ok, result} ->
            result

          :miss ->
            result = do_extract(tree, path)
            cache_put({blob, path}, result)
            result
        end
    end
  end

  @doc "Whether facts for `path` in `tree` are already cached."
  @spec cached?(Tree.t(), String.t()) :: boolean()
  def cached?(%Tree{} = tree, path) do
    case Tree.blob(tree, path) do
      nil -> false
      blob -> match?({:ok, _}, cache_get({blob, path}))
    end
  end

  @doc "Drops every cached fact set."
  @spec clear_cache() :: :ok
  def clear_cache do
    if :ets.whereis(@cache) != :undefined, do: :ets.delete_all_objects(@cache)
    :ok
  end

  # Facts are a pure function of a blob's contents, so the cache is keyed by blob oid and shared
  # by every process: a range of commits parses each distinct file version once. The table is
  # created by whoever needs it first; if that process dies the next user recreates it.
  defp cache_get(key) do
    case :ets.whereis(@cache) do
      :undefined ->
        :miss

      tid ->
        case :ets.lookup(tid, key) do
          [{^key, result}] -> {:ok, result}
          [] -> :miss
        end
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(key, result) do
    tid =
      case :ets.whereis(@cache) do
        :undefined -> create_cache()
        tid -> tid
      end

    if :ets.info(tid, :size) > @cache_limit, do: :ets.delete_all_objects(tid)
    :ets.insert(tid, {key, result})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp create_cache do
    :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])
  rescue
    # Another process created it first.
    ArgumentError -> :ets.whereis(@cache)
  end

  @doc "Extracts facts, returning an empty fact set for missing or unparseable files."
  @spec extract!(Tree.t(), String.t()) :: t()
  def extract!(tree, path) do
    case extract(tree, path) do
      {:ok, facts} -> facts
      {:error, _} -> %__MODULE__{path: path, modules: []}
    end
  end

  @doc """
  Extracts facts from source text directly (for tests and synthetic input).

  With `renames: %{Old => New}`, every resolved module reference — in
  function bodies and in the modules' own names — is mapped through the
  renames, so facts from before a rename can be compared with facts from
  after it.
  """
  @spec from_source(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_source(source, path \\ "nofile.ex", opts \\ []) do
    renames = Keyword.get(opts, :renames, %{})

    with {:ok, ast} <- Code.string_to_quoted(source, file: path, columns: true) do
      modules = ast |> collect_modules(path, [], %{renames: renames}) |> Enum.reverse()
      {:ok, %__MODULE__{path: path, modules: modules}}
    end
  rescue
    # A shape this extractor does not understand must not take the whole run down.
    e -> {:error, {:extract, path, Exception.message(e)}}
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

  # `defmodule unquote(name)` and `defmodule __MODULE__.Sub` have no literal name; their bodies
  # are still walked for nested literal modules.
  defp collect_modules({:defmodule, _meta, [name, [{:do, body}]]}, path, prefix, env)
       when not is_tuple(name) or elem(name, 0) != :__aliases__ do
    collect_modules(body, path, prefix, env)
  end

  defp collect_modules(
         {:defmodule, meta, [{:__aliases__, _, parts}, [{:do, body}]]},
         path,
         prefix,
         env
       )
       when is_list(parts) and parts != [] do
    if Enum.all?(parts, &is_atom/1),
      do: literal_module(meta, parts, body, path, prefix, env),
      else: collect_modules(body, path, prefix, env)
  end

  defp collect_modules({:defmodule, _meta, [_name, [{:do, body}]]}, path, prefix, env) do
    collect_modules(body, path, prefix, env)
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

  defp literal_module(meta, parts, body, path, prefix, env) do
    full = prefix ++ parts
    name = renamed(Elixir.Module.concat(full), env)
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
      functions: functions(items, name, path, moduledoc(items) == false, env),
      struct: struct_def(items),
      references: references(body, env, name),
      aliases: env |> Map.delete(:__MODULE__) |> Map.delete(:renames)
    }

    nested =
      Enum.reduce(items, [], fn item, acc -> collect_modules(item, path, full, env) ++ acc end)

    nested ++ [module]
  end

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
  defp functions(items, module, path, hidden?, env) do
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

          {kind, meta, [head | rest]}
          when kind in [:def, :defp, :defmacro, :defmacrop, :defdelegate] ->
            {name, arities} = head_arities(head)
            clause_hash = :erlang.phash2(normalize({head, rest}, env))
            full_arity = Enum.max(arities)
            delegate? = kind == :defdelegate
            kind = if delegate?, do: :def, else: kind

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
                    delegate?: delegate?,
                    module_hidden?: hidden?,
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

  # Clause identity ignores line metadata and expands aliases, so `alias A.B; B.f()` and `A.B.f()`
  # are the same body, and renaming an alias is not a behaviour change.
  defp normalize(ast, env) do
    Macro.prewalk(ast, fn
      {:__aliases__, _meta, parts} = node when is_list(parts) ->
        if Enum.all?(parts, &(is_atom(&1) or match?({:__MODULE__, _, _}, &1))),
          do:
            {:__aliases__, [],
             parts
             |> resolve(env)
             |> renamed(env)
             |> Elixir.Module.split()
             |> Enum.map(&String.to_atom/1)},
          else: node

      {a, _meta, b} ->
        {a, [], b}

      other ->
        other
    end)
  end

  defp renamed(module, env), do: Map.get(Map.get(env, :renames, %{}), module, module)

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
