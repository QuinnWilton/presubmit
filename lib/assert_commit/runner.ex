defmodule AssertCommit.Runner do
  @moduledoc """
  Runs rules against change sets and collects the outcomes.
  """

  alias AssertCommit.{Commit, Git, Rule}

  defmodule Result do
    @moduledoc "The outcome of one rule against one change set."
    @enforce_keys [:rule, :outcome]
    defstruct [:rule, :outcome]

    @type t :: %__MODULE__{rule: Rule.t(), outcome: Rule.outcome()}
  end

  defmodule Report do
    @moduledoc "Every rule's outcome for one change set."
    @enforce_keys [:commit, :results]
    defstruct [:commit, :results]

    @type t :: %__MODULE__{commit: Commit.t(), results: [Result.t()]}

    @doc "`:pass` when no rule failed or errored, `:error` when any rule crashed, else `:fail`."
    @spec status(t()) :: :pass | :fail | :error
    def status(%__MODULE__{results: results}) do
      cond do
        Enum.any?(results, &match?(%{outcome: {:error, _, _}}, &1)) -> :error
        Enum.any?(results, &match?(%{outcome: {:fail, _}}, &1)) -> :fail
        true -> :pass
      end
    end

    @doc "Counts of results by kind."
    @spec counts(t()) :: %{
            pass: non_neg_integer(),
            fail: non_neg_integer(),
            skip: non_neg_integer(),
            error: non_neg_integer()
          }
    def counts(%__MODULE__{results: results}) do
      Enum.reduce(results, %{pass: 0, fail: 0, skip: 0, error: 0}, fn %{outcome: outcome}, acc ->
        Map.update!(acc, kind(outcome), &(&1 + 1))
      end)
    end

    defp kind(:pass), do: :pass
    defp kind({:fail, _}), do: :fail
    defp kind({:skip, _}), do: :skip
    defp kind({:error, _, _}), do: :error
  end

  @doc "Runs every rule against the change set."
  @spec run(Commit.t(), [Rule.t()]) :: Report.t()
  def run(%Commit{} = commit, rules) when is_list(rules) do
    %Report{
      commit: commit,
      results: Enum.map(rules, &%Result{rule: &1, outcome: Rule.run(&1, commit)})
    }
  end

  @doc """
  Runs every rule against each non-merge commit in `range` (any `git rev-list`
  range, oldest first).
  """
  @spec run_range(Path.t(), String.t(), [Rule.t()]) :: [Report.t()]
  def run_range(repo, range, rules) do
    repo
    |> Git.run!(["rev-list", "--reverse", "--no-merges", range])
    |> String.split("\n", trim: true)
    |> Enum.map(fn sha -> run(Commit.rev(sha, repo: repo), rules) end)
  end
end
