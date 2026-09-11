defmodule AssertCommit.Assertions.Phoenix do
  @moduledoc """
  Assertions over Phoenix routers, controllers, and LiveViews, built on
  `AssertCommit.Adapters.PhoenixRouter` and `AssertCommit.Adapters.PhoenixHandler`.
  """

  alias AssertCommit.Adapters.{PhoenixHandler, PhoenixRouter}
  alias AssertCommit.Assertions.Flunk
  alias AssertCommit.{Commit, Source}

  @doc """
  Asserts every controller or LiveView the commit adds is routed by some
  router in the resulting tree.

  Routers are discovered across the tree, and plug modules are resolved
  through `scope` aliasing exactly as Phoenix does, so this holds whether
  the route was added in this commit or an earlier one, and fails even when
  the router file was edited for an unrelated reason.
  """
  @spec assert_routed(Commit.t()) :: :ok
  def assert_routed(%Commit{} = commit) do
    handlers =
      commit
      |> Source.models(PhoenixHandler)
      |> Map.fetch!(:added)
      |> Enum.filter(&PhoenixHandler.routable?/1)

    case handlers do
      [] ->
        :ok

      _ ->
        routers = Source.find(commit.after, PhoenixRouter, ~r{^lib/})

        unrouted =
          for h <- handlers, not Enum.any?(routers, &PhoenixRouter.routes?(&1, h.module)), do: h

        case {unrouted, routers} do
          {[], _} ->
            :ok

          {_, []} ->
            Flunk.flunk([
              "These #{describe(unrouted)} were added, but no Phoenix router was found under lib/:"
              | Flunk.indent(Enum.map(unrouted, &inspect(&1.module)))
            ])

          _ ->
            Flunk.flunk(
              ["These #{describe(unrouted)} were added but no router routes to them:"] ++
                Flunk.indent(Enum.map(unrouted, &"#{inspect(&1.module)} (#{&1.kind})")) ++
                ["", "Routers checked: #{Enum.map_join(routers, ", ", &inspect(&1.module))}"]
            )
        end
    end
  end

  @doc "Routes added by the commit, across every router it touched."
  @spec routes_added(Commit.t()) :: [PhoenixRouter.Route.t()]
  def routes_added(%Commit{} = commit) do
    %{added: added, modified: modified} = Source.models(commit, PhoenixRouter)

    Enum.flat_map(added, & &1.routes) ++
      Enum.flat_map(modified, fn {old, new} -> Enum.reject(new.routes, &route_in?(&1, old)) end)
  end

  @doc "Routes removed by the commit."
  @spec routes_removed(Commit.t()) :: [PhoenixRouter.Route.t()]
  def routes_removed(%Commit{} = commit) do
    %{removed: removed, modified: modified} = Source.models(commit, PhoenixRouter)

    Enum.flat_map(removed, & &1.routes) ++
      Enum.flat_map(modified, fn {old, new} -> Enum.reject(old.routes, &route_in?(&1, new)) end)
  end

  defp route_in?(route, router), do: Enum.any?(router.routes, &same_route?(&1, route))

  defp same_route?(a, b),
    do: {a.verb, a.path, a.plug, a.action} == {b.verb, b.path, b.plug, b.action}

  defp describe([%PhoenixHandler{kind: kind}]),
    do: to_string(kind) |> String.replace("_", " ") |> then(&"#{&1}s")

  defp describe(_), do: "controllers/LiveViews"
end
