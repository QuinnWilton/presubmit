defmodule AssertCommit.Rules.OTP do
  @moduledoc "OTP: every added process is started by a supervisor."
  use AssertCommit.RuleSet

  import AssertCommit.Assertions.OTP

  rule :supervised,
       "added GenServers, Agents, Tasks, and Supervisors are supervised",
       &assert_supervised/1
end
