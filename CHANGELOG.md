# Changelog

## Unreleased

### Added

- `mix assert_commit`: runs the rule sets in `.assert_commit.exs` (or every built-in set by default) against a change set and reports each rule as passed, failed, or skipped. Sources: `--head`, `--rev`, `--staged`, `--worktree`, `--range A..B`; the default is the working tree when anything differs from `HEAD`, else `HEAD`, and the first line of output always names what was examined. `--format json`, `--list`, and a warning when a dirty working tree is examined under `CI`.
- `mix assert_commit.install` writes a `commit-msg` hook (and, with `--pre-commit`, a `pre-commit` hook) that runs the policy on the staged changes; `--uninstall` removes them; a hook it did not write is never overwritten (`AssertCommit.Hooks`).
- `--message-file PATH` / `--message TEXT` attach a commit message to a `--staged` or `--worktree` change set so message rules run from a `commit-msg` hook; comment and scissors lines are stripped as git does (`Message.clean/1`, `AssertCommit.load/1` `message:`).
- Detection-aware defaults: rule sets declare `requires:` (`use AssertCommit.RuleSet, requires: [{:phoenix, Phoenix.Router}]`); without a `.assert_commit.exs`, `Config.default/1` enables `Rules.Phoenix`/`Rules.Ecto` when the library is loaded in the VM or is a declared or locked dependency of the examined tree, and `Rules.Changelog` when `CHANGELOG.md` exists. The output names what was enabled and why (`RuleSet.applicable?/2`, `Config.env/1`, JSON `config`).
- `Query.behaviour_changed?/2` and `function_changes/2` take a path pattern; `behaviour_changes_tested` is scoped to `lib/`, so a migration or script no longer demands a test change.
- Rule sets: `AssertCommit.RuleSet` (`use` + `rule/3`) and built-in `Rules.Elixir`, `Rules.Phoenix`, `Rules.Ecto`, `Rules.OTP`, `Rules.ExUnit`, `Rules.Mix`, `Rules.Changelog`, `Rules.Message`, `Rules.Hygiene`, `Rules.Shape`, with `only:`/`except:` and per-set options.
- Change sources: `Commit.worktree/1` (via a temporary index, never touching the real one) and `AssertCommit.load/1` with `source: :auto`.
- Structural source layer: `AssertCommit.Source.Facts` (per-file modules, functions, attributes, struct fields, alias-resolved references), `AssertCommit.Source.Diff` (modules and functions added/removed/renamed/changed, `behaviour_changed?/1`), `AssertCommit.Source.Index`.
- Library-aware adapters implementing `AssertCommit.Adapter`: `PhoenixRouter`, `PhoenixHandler`, `EctoSchema`, `EctoMigration`, `OtpProcess`, `ExUnitCase`; plus `AssertCommit.MixFile` and `AssertCommit.Changelog` parsers.
- Assertion verbs raising `AssertCommit.Violation`: library-aware (`assert_routed`, `assert_migrations_ordered`, `assert_schema_changes_migrated`, `assert_supervised`, `assert_tested`, `assert_lock_in_sync`, `assert_api_changes_logged`, …), Elixir-source (`assert_specs`, `assert_moduledoc`, `assert_removals_deprecated`, `assert_pure_move`, `assert_references`), file, line, message, and shape.
- `AssertCommit.Commit.new/1` for synthetic change sets; explicit errors for merge commits and shallow clones.
- `Source.Facts.Function.api?/1`: `@doc false` functions are not API, so `public_api_diff/1`, `assert_api_changes_logged`, and `assert_removals_deprecated` ignore them.
- Fixture repositories as base trees plus `format-patch` scenarios under `fixtures/`.

### Removed

- ExUnit hosting (`use AssertCommit`): rules run through `mix assert_commit` instead, so the source is chosen per invocation and announced in the output.
