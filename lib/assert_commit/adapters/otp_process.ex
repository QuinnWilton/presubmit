defmodule AssertCommit.Adapters.OtpProcess do
  @moduledoc """
  Models OTP behaviours and the children they start.

  Recognised by `use GenServer`, `use Agent`, `use Task`, `use Supervisor`,
  `use DynamicSupervisor`, `use Application`, or `use GenStateMachine`
  (and the `@behaviour` equivalents). Children are read from any list bound
  to a variable named `children`, or passed directly to
  `Supervisor.start_link/2` or `Supervisor.init/2`; each child spec is
  reduced to its module (`Mod`, `{Mod, arg}`, `%{start: {Mod, _, _}}`,
  `Mod.child_spec(...)`).
  """

  @behaviour AssertCommit.Adapter

  alias AssertCommit.Source.Facts
  alias AssertCommit.Source.Facts.Module

  @enforce_keys [:module, :kind]
  defstruct [:module, :kind, children: []]

  @type kind ::
          :gen_server
          | :agent
          | :task
          | :supervisor
          | :dynamic_supervisor
          | :application
          | :gen_statem
  @type t :: %__MODULE__{module: module(), kind: kind(), children: [module()]}

  @kinds %{
    GenServer => :gen_server,
    Agent => :agent,
    Task => :task,
    Supervisor => :supervisor,
    DynamicSupervisor => :dynamic_supervisor,
    Application => :application,
    GenStateMachine => :gen_statem,
    :gen_statem => :gen_statem
  }

  @impl true
  def recognize?(%Module{} = module), do: kind(module) != nil

  @impl true
  def extract(%Module{} = module) do
    env = Map.put(module.aliases, :__MODULE__, module.name)
    %__MODULE__{module: module.name, kind: kind(module), children: children(module.body, env)}
  end

  @doc "Whether the process is one that must be started by something else."
  @spec worker?(t()) :: boolean()
  def worker?(%__MODULE__{kind: kind}),
    do: kind in [:gen_server, :agent, :task, :gen_statem, :supervisor, :dynamic_supervisor]

  @doc "Whether the process starts `child`."
  @spec starts?(t(), module()) :: boolean()
  def starts?(%__MODULE__{children: children}, child), do: child in children

  defp kind(%Module{uses: uses, behaviours: behaviours}) do
    Enum.find_value(uses, fn {target, _} -> @kinds[target] end) ||
      Enum.find_value(behaviours, fn target -> @kinds[target] end)
  end

  defp children(body, env) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {:=, _, [{:children, _, ctx}, list]} = node, acc when is_atom(ctx) and is_list(list) ->
          {node, acc ++ specs(list, env)}

        {{:., _, [{:__aliases__, _, [:Supervisor]}, fun]}, _, [list | _]} = node, acc
        when fun in [:start_link, :init] and is_list(list) ->
          {node, acc ++ specs(list, env)}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(acc)
  end

  defp specs(list, env), do: Enum.flat_map(list, &spec_module(&1, env))

  defp spec_module({:__aliases__, _, parts}, env), do: [Facts.resolve(parts, env)]
  defp spec_module({{:__aliases__, _, parts}, _arg}, env), do: [Facts.resolve(parts, env)]
  defp spec_module({:{}, _, [{:__aliases__, _, parts} | _]}, env), do: [Facts.resolve(parts, env)]

  defp spec_module({:%{}, _, fields}, env) when is_list(fields),
    do: spec_module(Keyword.get(fields, :start), env)

  defp spec_module({{:., _, [{:__aliases__, _, parts}, :child_spec]}, _, _}, env),
    do: [Facts.resolve(parts, env)]

  defp spec_module(atom, _env) when is_atom(atom) and not is_nil(atom), do: [atom]
  defp spec_module(_, _env), do: []
end
