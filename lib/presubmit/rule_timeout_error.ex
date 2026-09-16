defmodule Presubmit.RuleTimeoutError do
  @moduledoc """
  Reported (never raised) when a rule does not finish within the runner's
  timeout; the rule is killed and the run continues.
  """

  defexception [:rule, :timeout]

  @type t :: %__MODULE__{rule: atom(), timeout: pos_integer()}

  @impl true
  def message(%__MODULE__{rule: rule, timeout: timeout}) do
    "rule #{inspect(rule)} did not finish within #{div(timeout, 1000)}s and was stopped"
  end
end
