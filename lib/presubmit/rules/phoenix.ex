defmodule Presubmit.Rules.Phoenix do
  @moduledoc "Phoenix: every added controller and LiveView is routed."
  use Presubmit.RuleSet, requires: [{:phoenix, Phoenix.Router}]

  import Presubmit.Assertions.Phoenix

  rule :routed, "added controllers and LiveViews are routed", &assert_routed/1
end
