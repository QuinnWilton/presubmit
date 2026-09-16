defmodule Presubmit.Rules.Mix do
  @moduledoc "Mix: mix.lock moves with mix.exs."
  use Presubmit.RuleSet

  import Presubmit.Assertions.Mix

  rule :lock_in_sync, "mix.lock is in sync with mix.exs", &assert_lock_in_sync/1
end
