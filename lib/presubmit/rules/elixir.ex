defmodule Presubmit.Rules.Elixir do
  @moduledoc "Elixir source hygiene: specs, docs, deprecation before removal, pure moves."
  use Presubmit.RuleSet

  import Presubmit.Assertions

  rule :specs, "new public functions have a @spec", &assert_specs/1
  rule :moduledoc, "new modules have a @moduledoc", &assert_moduledoc/1

  rule :removals_deprecated,
       "removed public functions were @deprecated first",
       &assert_removals_deprecated/1

  rule :pure_move, "a commit that renames files contains nothing else", &assert_pure_move/1
end
