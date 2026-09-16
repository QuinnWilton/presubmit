defmodule Presubmit.Rules.ExUnit do
  @moduledoc "ExUnit: new modules and behaviour changes come with tests."
  use Presubmit.RuleSet

  import Presubmit.Assertions.ExUnit

  rule :tested, "added modules have a test module", &assert_tested/1

  rule :behaviour_changes_tested,
       "behaviour changes in lib/ come with test changes",
       &assert_behaviour_changes_tested/1
end
