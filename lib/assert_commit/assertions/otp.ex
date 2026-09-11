defmodule AssertCommit.Assertions.OTP do
  @moduledoc """
  Assertions over OTP processes and supervision trees, built on
  `AssertCommit.Adapters.OtpProcess`.
  """

  alias AssertCommit.Adapters.OtpProcess
  alias AssertCommit.Assertions.Flunk
  alias AssertCommit.{Commit, Source}

  @doc """
  Asserts every GenServer, Agent, Task, or Supervisor module the commit adds
  is started by some supervisor or application in the resulting tree.
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
          commit.after |> Source.find(OtpProcess, ~r{^lib/}) |> Enum.filter(&(&1.children != []))

        orphans =
          for w <- workers, not Enum.any?(supervisors, &OtpProcess.starts?(&1, w.module)), do: w

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

  defp describe([]), do: "none found under lib/"
  defp describe(supervisors), do: Enum.map_join(supervisors, ", ", &inspect(&1.module))
end
