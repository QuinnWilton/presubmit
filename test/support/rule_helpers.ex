defmodule Presubmit.RuleHelpers do
  @moduledoc """
  Runs individual rules from a rule set against a fixture scenario, for the
  scenario suites.
  """

  alias Presubmit.{Commit, Rule, RuleSet}

  @doc "Loads `scenario/<name>` from a fixture repository."
  @spec scenario(Path.t(), atom()) :: Commit.t()
  def scenario(repo, name), do: Commit.rev("scenario/#{name}", repo: repo)

  @doc "Runs rule `id` of `set` (configured with `opts`) against `commit`."
  @spec run_rule(module(), atom(), Commit.t(), keyword()) :: Rule.outcome()
  def run_rule(set, id, %Commit{} = commit, opts \\ []) do
    case RuleSet.expand({set, [only: [id]] ++ opts}) do
      [rule] -> Rule.run(rule, commit)
    end
  end

  @doc "Asserts a rule passes."
  defmacro assert_pass(outcome) do
    quote do
      assert :pass = unquote(outcome)
    end
  end

  @doc "Asserts a rule fails, binding the failure message."
  defmacro assert_fail(outcome, message_var) do
    quote do
      assert {:fail, unquote(message_var)} = unquote(outcome)
    end
  end
end
