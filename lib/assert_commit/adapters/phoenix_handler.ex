defmodule AssertCommit.Adapters.PhoenixHandler do
  @moduledoc """
  Models the modules a Phoenix router can route to: controllers, LiveViews,
  and LiveComponents, plus channels.

  Recognised by `use Phoenix.Controller`, `use Phoenix.LiveView`,
  `use Phoenix.LiveComponent`, `use Phoenix.Channel`, or the conventional
  `use MyAppWeb, :controller` / `:live_view` / `:live_component` / `:channel`.
  An `action_fallback` declaration is recorded as `fallback`.
  """

  @behaviour AssertCommit.Adapter

  alias AssertCommit.Source.Facts.Module

  @enforce_keys [:module, :kind]
  defstruct [:module, :kind, fallback: nil]

  @type kind :: :controller | :live_view | :live_component | :channel
  @type t :: %__MODULE__{module: module(), kind: kind(), fallback: module() | nil}

  @direct %{
    Phoenix.Controller => :controller,
    Phoenix.LiveView => :live_view,
    Phoenix.LiveComponent => :live_component,
    Phoenix.Channel => :channel
  }
  @conventional [:controller, :live_view, :live_component, :channel]

  @impl true
  def recognize?(%Module{} = module), do: kind(module) != nil

  @impl true
  def extract(%Module{} = module) do
    %__MODULE__{module: module.name, kind: kind(module), fallback: fallback(module)}
  end

  # `action_fallback MyAppWeb.FallbackController`: a controller that is never routed by design.
  defp fallback(%Module{body: body, aliases: aliases, name: name}) do
    env = Map.put(aliases, :__MODULE__, name)

    Enum.find_value(block_items(body), fn
      {:action_fallback, _, [{:__aliases__, _, parts}]} ->
        AssertCommit.Source.Facts.resolve(parts, env)

      _ ->
        nil
    end)
  end

  defp block_items({:__block__, _, items}), do: items
  defp block_items(nil), do: []
  defp block_items(item), do: [item]

  @doc "Kinds that are targets of routes (as opposed to channels and components)."
  @spec routable?(t()) :: boolean()
  def routable?(%__MODULE__{kind: kind}), do: kind in [:controller, :live_view]

  defp kind(%Module{uses: uses}) do
    Enum.find_value(uses, fn
      {target, _} when is_map_key(@direct, target) -> @direct[target]
      {_, [kind | _]} when kind in @conventional -> kind
      _ -> nil
    end)
  end
end
