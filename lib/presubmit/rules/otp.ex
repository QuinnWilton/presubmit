defmodule Presubmit.Rules.OTP do
  @moduledoc "OTP: every added process is started by a supervisor."
  use Presubmit.RuleSet

  import Presubmit.Assertions.OTP

  rule :supervised,
       "added GenServers, Agents, Tasks, and Supervisors are supervised",
       &assert_supervised/1
end
