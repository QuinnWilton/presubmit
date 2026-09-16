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

    @doc "Whether any rule warned."
    @spec warnings?(t()) :: boolean()
    def warnings?(%__MODULE__{results: results}),
      do: Enum.any?(results, &match?(%{outcome: {:warn, _}}, &1))

    @doc "Counts of results by kind."
    @spec counts(t()) :: %{
            pass: non_neg_integer(),
            fail: non_neg_integer(),
            warn: non_neg_integer(),
            skip: non_neg_integer(),
            error: non_neg_integer()
          }
    def counts(%__MODULE__{results: results}) do
      Enum.reduce(results, %{pass: 0, fail: 0, warn: 0, skip: 0, error: 0}, fn %{outcome: outcome},
                                                                               acc ->
        Map.update!(acc, kind(outcome), &(&1 + 1))
      end)
    end

    defp kind(:pass), do: :pass
    defp kind({:fail, _}), do: :fail
    defp kind({:warn, _}), do: :warn
    defp kind({:skip, _}), do: :skip
    defp kind({:error, _, _}), do: :error
  end

  @default_timeout 30_000

  @doc """
  Runs every rule against the change set.

  Rules run in a worker process, so a rule that does not finish within `opts[:timeout]` milliseconds
  (default 30 seconds) is stopped and reported as an
  `AssertCommit.RuleTimeoutError`; the remaining rules run in a fresh worker.
  """
  @spec run(Commit.t(), [Rule.t()], keyword()) :: Report.t()
  def run(%Commit{} = commit, rules, opts \\ []) when is_list(rules) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    %Report{commit: commit, results: run_rules(rules, commit, timeout, [])}
  end

  defp run_rules([], _commit, _timeout, acc), do: Enum.reverse(acc)

  defp run_rules(rules, commit, timeout, acc) do
    parent = self()
    ref = make_ref()

    worker =
      Task.async(fn ->
        Enum.each(rules, fn rule -> send(parent, {ref, rule.id, Rule.run(rule, commit)}) end)
      end)

    collect(rules, worker, ref, commit, timeout, acc)
  end

  defp collect([], worker, _ref, _commit, _timeout, acc) do
    Task.await(worker, :infinity)
    Enum.reverse(acc)
  end

  defp collect([rule | rest], worker, ref, commit, timeout, acc) do
    receive do
      {^ref, id, outcome} when id == rule.id ->
        collect(rest, worker, ref, commit, timeout, [%Result{rule: rule, outcome: outcome} | acc])
    after
      timeout ->
        Task.shutdown(worker, :brutal_kill)
        error = %AssertCommit.RuleTimeoutError{rule: rule.id, timeout: timeout}

        run_rules(rest, commit, timeout, [%Result{rule: rule, outcome: {:error, error, []}} | acc])
    end
  end

  @doc """
  Runs every rule against each non-merge commit in `range` (any `git rev-list`
  range, oldest first).
  """
  @spec run_range(Path.t(), String.t(), [Rule.t()], keyword()) :: [Report.t()]
  def run_range(repo, range, rules, opts \\ []) do
    repo
    |> Git.run!(["rev-list", "--reverse", "--no-merges", range])
    |> String.split("\n", trim: true)
    |> Enum.map(fn sha ->
      run(Commit.rev(sha, repo: repo), rules, opts)
    end)
  end
end
