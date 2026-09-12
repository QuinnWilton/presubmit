defmodule AssertCommit.Rules.Phoenix do
  @moduledoc "Phoenix: every added controller and LiveView is routed."
  use AssertCommit.RuleSet, requires: [{:phoenix, Phoenix.Router}]

  import AssertCommit.Assertions.Phoenix

  rule :routed, "added controllers and LiveViews are routed", &assert_routed/1
end
