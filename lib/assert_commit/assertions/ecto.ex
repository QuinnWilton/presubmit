defmodule AssertCommit.Assertions.Ecto do
  @moduledoc """
  Assertions over Ecto schemas and migrations, built on
  `AssertCommit.Adapters.EctoSchema` and `AssertCommit.Adapters.EctoMigration`.

  Migrations are discovered by `use Ecto.Migration` rather than by path, so
  a non-standard `priv/*/migrations` layout works unchanged.
  """

  alias AssertCommit.Adapters.{EctoMigration, EctoSchema}
  alias AssertCommit.Assertions.Flunk
  alias AssertCommit.{Commit, Source}

  @migration_files ~r{/migrations/.*\.exs$}

  @doc "Migrations the commit adds."
  @spec migrations_added(Commit.t()) :: [EctoMigration.t()]
  def migrations_added(%Commit{} = commit), do: Source.models(commit, EctoMigration).added

  @doc "Every migration in the resulting tree, oldest first."
  @spec migrations(Commit.t()) :: [EctoMigration.t()]
  def migrations(%Commit{after: tree}),
    do: tree |> Source.find(EctoMigration, @migration_files) |> Enum.sort_by(& &1.version)

  @doc """
  Asserts every migration the commit adds has a version newer than every
  migration that already existed.

  A migration generated on a branch and rebased onto newer ones would sort
  before them and never run on a database that already applied the newer
  ones.
  """
  @spec assert_migrations_ordered(Commit.t()) :: :ok
  def assert_migrations_ordered(%Commit{} = commit) do
    added = migrations_added(commit)

    existing =
      commit.before
      |> Source.find(EctoMigration, @migration_files)
      |> Enum.map(& &1.version)
      |> Enum.reject(&is_nil/1)

    newest = Enum.max(existing, fn -> nil end)

    stale = for m <- added, newest != nil and m.version != nil and m.version <= newest, do: m

    case stale do
      [] ->
        :ok

      _ ->
        Flunk.flunk(
          ["These added migrations are older than the newest existing migration (#{newest}):"] ++
            Flunk.indent(Enum.map(stale, &"#{&1.path} (#{&1.version})")) ++
            [
              "",
              "Regenerate them so their timestamps are the newest, or they will run out of order."
            ]
        )
    end
  end

  @doc """
  Asserts that migrations which existed before the commit are unchanged:
  not modified, deleted, or renamed.
  """
  @spec assert_migrations_immutable(Commit.t()) :: :ok
  def assert_migrations_immutable(%Commit{} = commit) do
    %{removed: removed, modified: modified} = Source.models(commit, EctoMigration)

    problems =
      Enum.map(removed, &"#{&1.path} (removed)") ++
        Enum.map(modified, fn {old, new} ->
          if old.path == new.path,
            do: "#{new.path} (modified)",
            else: "#{old.path} → #{new.path} (renamed)"
        end)

    case problems do
      [] ->
        :ok

      _ ->
        Flunk.flunk([
          "Migrations are immutable once committed, but this commit changes:"
          | Flunk.indent(problems)
        ])
    end
  end

  @doc """
  Asserts every column a schema gains in this commit is added to the
  schema's table by a migration in this commit.

  Only `field` and `belongs_to` declarations map to columns; associations
  and embeds are ignored. Schemas without a `source` (embedded) are skipped.
  """
  @spec assert_schema_changes_migrated(Commit.t()) :: :ok
  def assert_schema_changes_migrated(%Commit{} = commit) do
    %{added: added, modified: modified} = Source.models(commit, EctoSchema)
    migrations = migrations_added(commit)

    needed =
      for {schema, columns} <-
            Enum.map(added, &{&1, EctoSchema.columns(&1)}) ++
              Enum.map(modified, fn {old, new} ->
                {new, EctoSchema.columns(new) -- EctoSchema.columns(old)}
              end),
          schema.source != nil,
          column <- columns,
          not Enum.any?(migrations, &(column in EctoMigration.columns_added(&1, schema.source))),
          do: "#{inspect(schema.module)}.#{column} (table #{inspect(schema.source)})"

    case needed do
      [] ->
        :ok

      _ ->
        Flunk.flunk(
          ["These schema columns were added without a migration adding them to the table:"] ++
            Flunk.indent(needed) ++
            [
              "",
              if(migrations == [],
                do: "No migration was added in this commit.",
                else: "Migrations added: #{Enum.map_join(migrations, ", ", & &1.path)}"
              )
            ]
        )
    end
  end

  @doc """
  Asserts every index the commit creates is created `concurrently: true`
  inside a migration that disables the DDL transaction, so it does not lock
  the table on PostgreSQL.
  """
  @spec assert_indexes_concurrent(Commit.t()) :: :ok
  def assert_indexes_concurrent(%Commit{} = commit) do
    problems =
      for m <- migrations_added(commit),
          {_, {:create_index, table, columns, opts}} <- m.ops,
          problem <- index_problems(m, table, columns, opts),
          do: problem

    case problems do
      [] ->
        :ok

      _ ->
        Flunk.flunk([
          "These indexes would lock their table while being built:" | Flunk.indent(problems)
        ])
    end
  end

  defp index_problems(m, table, columns, opts) do
    desc = "#{m.path}: index on #{inspect(table)} #{inspect(columns)}"

    Enum.reject(
      [
        if(not Keyword.get(opts, :concurrently, false),
          do: "#{desc} is missing `concurrently: true`"
        ),
        if(not m.disable_ddl_transaction?,
          do: "#{desc} needs `@disable_ddl_transaction true` on #{inspect(m.module)}"
        )
      ],
      &is_nil/1
    )
  end

  @doc """
  Asserts every migration the commit adds can be rolled back: it defines
  `down/0`, or a `change/0` whose `execute` calls all provide a down statement.
  """
  @spec assert_migrations_reversible(Commit.t()) :: :ok
  def assert_migrations_reversible(%Commit{} = commit) do
    irreversible = for m <- migrations_added(commit), not EctoMigration.reversible?(m), do: m.path

    case irreversible do
      [] ->
        :ok

      _ ->
        Flunk.flunk([
          "These migrations cannot be rolled back (raw `execute/1` in `change/0`, or no `down/0`):"
          | Flunk.indent(irreversible)
        ])
    end
  end
end
