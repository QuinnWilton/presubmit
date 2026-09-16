defmodule Presubmit.Concuerror.RunnerTimeout do
  @moduledoc """
  Concuerror scenario: the runner's worker/timeout protocol. A slow rule
  may report just before or just after the timeout fires; either way every
  rule gets exactly one result, in order, the killed worker leaves nothing
  in the caller's mailbox, and later rules still run.

  Run with `mix presubmit.concuerror` (see `test/concuerror/run.exs`).
  """

  alias Presubmit.{Commit, Rule, RuleTimeoutError, Runner}

  @doc false
  def run do
    commit = Commit.new(before: %{}, after: %{})

    slow =
      Rule.new(:slow, "slow", fn _ ->
        receive do
        after
          10 -> :ok
        end
      end)

    fast = Rule.new(:fast, "fast", fn _ -> :ok end)

    report = Runner.run(commit, [slow, fast, slow], timeout: 5)
    [:slow, :fast, :slow] = Enum.map(report.results, & &1.rule.id)

    for result <- report.results do
      case result.outcome do
        :pass -> :ok
        {:error, %RuleTimeoutError{}, _} -> :ok
      end
    end

    {:message_queue_len, 0} = Process.info(self(), :message_queue_len)
    :ok
  end
end
