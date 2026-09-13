defmodule AssertCommit.Assertions.OTP do
  @moduledoc """
  Assertions over OTP processes and supervision trees, built on
  `AssertCommit.Adapters.OtpProcess`.
  """

  alias AssertCommit.Adapters.OtpProcess
  alias AssertCommit.Assertions.Flunk
  alias AssertCommit.{Commit, Paths, Source}
  alias AssertCommit.Source.Index

  @doc """
  Asserts every GenServer, Agent, Task, or Supervisor module the commit adds
  is started by some supervisor or application in the resulting tree.

  Processes started dynamically (`DynamicSupervisor.start_child`,
  `Task.Supervisor`, a child list built in a function) have no static child
  spec; a module that any *other* module under `lib/` names is taken to be
  started that way and passes.
  """
  @spec assert_supervised(Commit.t()) :: :ok
  def assert_supervised(%Commit{} = commit) do
    workers =
      commit
      |> Source.models(OtpProcess)
      |> Map.fetch!(:added)
      |> Enum.filter(&OtpProcess.worker?/1)

    case workers do
      [] ->
        :ok

      _ ->
        supervisors =
          commit.after
          |> Source.find(OtpProcess, Paths.lib())
          |> Enum.filter(&(&1.children != []))

        modules = Index.modules(commit.after, Paths.lib())

        orphans =
          for w <- workers,
              not Enum.any?(supervisors, &OtpProcess.starts?(&1, w.module)),
              not Enum.any?(modules, &(&1.name != w.module and w.module in &1.references)),
              do: w

        case orphans do
          [] ->
            :ok

          _ ->
            Flunk.flunk(
              ["These processes were added but nothing starts them:"] ++
                Flunk.indent(Enum.map(orphans, &"#{inspect(&1.module)} (#{&1.kind})")) ++
                ["", "Supervision trees checked: #{describe(supervisors)}"]
            )
        end
    end
  end

  defp describe([]), do: "none found under any lib/"
  defp describe(supervisors), do: Enum.map_join(supervisors, ", ", &inspect(&1.module))
end
