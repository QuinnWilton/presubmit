defmodule Presubmit.Adapters.PhoenixRouter do
  @moduledoc """
  Models Phoenix routers (`use Phoenix.Router`, or `use MyAppWeb, :router`)
  as a flat list of routes with plug modules fully resolved.

  Recognised shapes: `scope` (with a positional alias, `alias:` option, or
  neither) nested to any depth, the HTTP verb macros, `match`, `live`,
  `live_session`, `forward`, and `resources` (expanded to its actions,
  honouring `only:`/`except:`/`singleton:`).

  Phoenix concatenates the enclosing scope aliases onto a route's plug, so
  `get "/posts", PostController` inside `scope "/", MyAppWeb` resolves to
  `MyAppWeb.PostController`. That resolution is reproduced here.
  """

  @behaviour Presubmit.Adapter

  alias Presubmit.Source.Facts
  alias Presubmit.Source.Facts.Module

  defmodule Route do
    @moduledoc "One route: verb, full path, resolved plug module, and action."
    @enforce_keys [:kind, :verb, :path, :plug, :line]
    defstruct [:kind, :verb, :path, :plug, :action, :line]

    @type t :: %__MODULE__{
            kind: :match | :live | :forward | :resources,
            verb: atom(),
            path: String.t(),
            plug: module(),
            action: atom() | nil,
            line: pos_integer()
          }
  end

  @enforce_keys [:module, :routes]
  defstruct [:module, :routes]

  @type t :: %__MODULE__{module: module(), routes: [Route.t()]}

  @verbs [:get, :post, :put, :patch, :delete, :options, :head, :connect, :trace, :match]
  @resource_actions [:index, :new, :create, :show, :edit, :update, :delete]
  @singleton_actions [:new, :create, :show, :edit, :update, :delete]

  @impl true
  def recognize?(%Module{} = module) do
    Module.uses?(module, Phoenix.Router) or
      Enum.any?(module.uses, &match?({_, [:router | _]}, &1))
  end

  @impl true
  def extract(%Module{} = module) do
    env = Map.put(module.aliases, :__MODULE__, module.name)

    routes =
      module.body
      |> block_items()
      |> Enum.flat_map(&routes(&1, "", [], env))
      |> Enum.sort_by(& &1.line)

    %__MODULE__{module: module.name, routes: routes}
  end

  @doc "Every plug module the router routes to."
  @spec plugs(t()) :: [module()]
  def plugs(%__MODULE__{routes: routes}), do: routes |> Enum.map(& &1.plug) |> Enum.uniq()

  @doc "Whether the router has a route to `plug`."
  @spec routes?(t(), module()) :: boolean()
  def routes?(%__MODULE__{} = router, plug), do: plug in plugs(router)

  defp routes({:scope, _, args}, prefix, scopes, env) do
    {path, alias_parts, opts, block} = scope_args(args)
    scopes = scopes ++ scope_alias(alias_parts, opts, env)
    block |> block_items() |> Enum.flat_map(&routes(&1, join(prefix, path), scopes, env))
  end

  defp routes({:live_session, _, [_name | rest]}, prefix, scopes, env) do
    case List.last(rest) do
      [do: block] -> block |> block_items() |> Enum.flat_map(&routes(&1, prefix, scopes, env))
      _ -> []
    end
  end

  defp routes({verb, meta, [path, plug, action | _]}, prefix, scopes, env)
       when verb in @verbs and is_binary(path) do
    [
      %Route{
        kind: :match,
        verb: verb,
        path: join(prefix, path),
        plug: resolve(plug, scopes, env),
        action: action,
        line: line(meta)
      }
    ]
  end

  defp routes({:live, meta, [path, plug | rest]}, prefix, scopes, env) when is_binary(path) do
    action = Enum.find(rest, &is_atom/1)

    [
      %Route{
        kind: :live,
        verb: :get,
        path: join(prefix, path),
        plug: resolve(plug, scopes, env),
        action: action,
        line: line(meta)
      }
    ]
  end

  defp routes({:forward, meta, [path, plug | _]}, prefix, scopes, env) when is_binary(path) do
    [
      %Route{
        kind: :forward,
        verb: :*,
        path: join(prefix, path),
        plug: resolve(plug, scopes, env),
        action: nil,
        line: line(meta)
      }
    ]
  end

  defp routes({:resources, meta, [path, plug | rest]}, prefix, scopes, env)
       when is_binary(path) do
    opts = Enum.find(rest, [], &Keyword.keyword?/1)
    actions = resource_actions(opts)
    module = resolve(plug, scopes, env)

    nested =
      case List.last(rest) do
        [do: block] ->
          block
          |> block_items()
          |> Enum.flat_map(&routes(&1, join(prefix, path <> "/:id"), scopes, env))

        _ ->
          []
      end

    for action <- actions do
      %Route{
        kind: :resources,
        verb: resource_verb(action),
        path: join(prefix, path),
        plug: module,
        action: action,
        line: line(meta)
      }
    end ++ nested
  end

  defp routes(_, _prefix, _scopes, _env), do: []

  # scope "/path" do / scope "/path", Alias do / scope "/path", Alias, opts do / scope "/path", opts do / scope opts do
  defp scope_args([path, {:__aliases__, _, parts}, opts, [do: block]]) when is_binary(path),
    do: {path, parts, opts, block}

  defp scope_args([path, {:__aliases__, _, parts}, [do: block]]) when is_binary(path),
    do: {path, parts, [], block}

  defp scope_args([path, opts, [do: block]]) when is_binary(path) and is_list(opts),
    do: {path, nil, opts, block}

  defp scope_args([path, [do: block]]) when is_binary(path), do: {path, nil, [], block}

  defp scope_args([opts, [do: block]]) when is_list(opts),
    do: {Keyword.get(opts, :path, ""), nil, opts, block}

  defp scope_args(_), do: {"", nil, [], nil}

  defp scope_alias(nil, opts, env) do
    case Keyword.get(opts, :alias) do
      {:__aliases__, _, parts} -> [Facts.resolve(parts, env)]
      false -> [false]
      _ -> []
    end
  end

  defp scope_alias(parts, _opts, env), do: [Facts.resolve(parts, env)]

  # Phoenix: Module.concat(scope aliases ++ [plug]) unless a scope set `alias: false`.
  defp resolve({:__aliases__, _, parts}, scopes, env) do
    plug = Facts.resolve(parts, env)
    prefix = scopes |> Enum.reverse() |> Enum.take_while(&(&1 != false)) |> Enum.reverse()

    case prefix do
      [] -> plug
      _ -> Elixir.Module.concat(prefix ++ [plug])
    end
  end

  defp resolve(atom, _scopes, _env) when is_atom(atom), do: atom
  defp resolve(other, _scopes, _env), do: :"#{Macro.to_string(other)}"

  defp resource_actions(opts) do
    base =
      if Keyword.get(opts, :singleton, false), do: @singleton_actions, else: @resource_actions

    cond do
      only = Keyword.get(opts, :only) -> Enum.filter(base, &(&1 in only))
      except = Keyword.get(opts, :except) -> Enum.reject(base, &(&1 in except))
      true -> base
    end
  end

  defp resource_verb(:index), do: :get
  defp resource_verb(:new), do: :get
  defp resource_verb(:show), do: :get
  defp resource_verb(:edit), do: :get
  defp resource_verb(:create), do: :post
  defp resource_verb(:update), do: :patch
  defp resource_verb(:delete), do: :delete

  defp join("", path), do: path
  defp join(prefix, "/"), do: prefix

  defp join(prefix, path),
    do: String.trim_trailing(prefix, "/") <> "/" <> String.trim_leading(path, "/")

  defp line(meta), do: Keyword.get(meta, :line, 0)

  defp block_items({:__block__, _, items}), do: items
  defp block_items(nil), do: []
  defp block_items(item), do: [item]
end
