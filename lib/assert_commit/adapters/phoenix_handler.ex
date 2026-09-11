defmodule AssertCommit.Adapters.PhoenixHandler do
  @moduledoc """
  Models the modules a Phoenix router can route to: controllers, LiveViews,
  and LiveComponents, plus channels.

  Recognised by `use Phoenix.Controller`, `use Phoenix.LiveView`,
  `use Phoenix.LiveComponent`, `use Phoenix.Channel`, or the conventional
  `use MyAppWeb, :controller` / `:live_view` / `:live_component` / `:channel`.
  """

  @behaviour AssertCommit.Adapter

  alias AssertCommit.Source.Facts.Module

  @enforce_keys [:module, :kind]
  defstruct [:module, :kind]

  @type kind :: :controller | :live_view | :live_component | :channel
  @type t :: %__MODULE__{module: module(), kind: kind()}

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
  def extract(%Module{} = module), do: %__MODULE__{module: module.name, kind: kind(module)}

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
