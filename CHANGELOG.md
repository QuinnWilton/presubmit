# Changelog

## Unreleased

### Added

- `use AssertCommit` loads `HEAD`, any revision, or the staged index into the test context as `commit`; options may be functions of the test context for per-test revisions.
- Structural source layer: `AssertCommit.Source.Facts` (per-file modules, functions, attributes, struct fields, alias-resolved references), `AssertCommit.Source.Diff` (modules and functions added/removed/renamed/changed, `behaviour_changed?/1`), `AssertCommit.Source.Index` (tree-wide discovery).
- Library-aware adapters implementing `AssertCommit.Adapter`: `PhoenixRouter`, `PhoenixHandler`, `EctoSchema`, `EctoMigration`, `OtpProcess`, `ExUnitCase`; plus `AssertCommit.MixFile` and `AssertCommit.Changelog` parsers.
- Library-aware assertions: `assert_routed`, `assert_migrations_ordered`, `assert_migrations_immutable`, `assert_schema_changes_migrated`, `assert_indexes_concurrent`, `assert_migrations_reversible`, `assert_supervised`, `assert_tested`, `assert_behaviour_changes_tested`, `assert_lock_in_sync`, `assert_release_logged`, `assert_api_changes_logged`.
- Elixir-source assertions on the structural diff: `assert_specs`, `assert_moduledoc`, `assert_removals_deprecated`, `assert_pure_move`, `assert_references`.
- File, line, message, and shape assertions: `assert_added`/`refute_added` and friends, `assert_immutable`, `assert_coupled`, `assert_counterpart`, `assert_last_by_name`, `refute_added_lines`, `assert_subject`, `assert_trailer`, `assert_scope_matches_paths`, `assert_max_files`, `assert_max_additions`.
- `AssertCommit.Commit.new/1` for synthetic change sets in tests.
- Explicit errors for merge commits and shallow clones, with the CI fix in the message.
- Fixture repositories as base trees plus `format-patch` scenarios under `fixtures/`, loaded by `AssertCommit.Fixtures`.
