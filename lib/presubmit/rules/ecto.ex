defmodule Presubmit.Rules.Ecto do
  @moduledoc """
  Ecto: migrations are ordered, immutable, safe, reversible, and back every schema change.

  Option `since:` (a ref such as `"origin/main"`) makes only migrations present on that ref
  immutable, so unmerged ones can still be edited.
  """
  use Presubmit.RuleSet, requires: [{[:ecto, :ecto_sql], Ecto.Schema}]

  import Presubmit.Assertions.Ecto

  rule :migrations_ordered,
       "added migrations are newer than every existing one",
       &assert_migrations_ordered/1

  rule :migrations_immutable, "committed migrations are never edited", fn commit, opts ->
    assert_migrations_immutable(commit, Keyword.take(opts, [:since]))
  end

  rule :schema_changes_migrated,
       "schema columns are added by a migration in the same commit",
       &assert_schema_changes_migrated/1

  rule :indexes_concurrent, "indexes are created concurrently", &assert_indexes_concurrent/1

  rule :migrations_reversible,
       "added migrations can be rolled back",
       &assert_migrations_reversible/1
end
