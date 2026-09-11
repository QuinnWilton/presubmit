# assert_commit

[![CI](https://github.com/QuinnWilton/assert_commit/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/assert_commit/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/assert_commit.svg)](https://hex.pm/packages/assert_commit)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/assert_commit)

ExUnit assertions over the shape and contents of git commits.

A test suite proves that the code at `HEAD` works. It says nothing about
whether the *commit* is one your process would accept: whether the migration
it adds will run in order, whether the controller it adds is reachable, whether
the public function it removes was ever deprecated, whether a move was landed
on its own. assert_commit loads `HEAD` (or the staged index, or any revision)
into your test context, parses the Elixir it changed into a structural
description — modules, functions, schema fields, routes, child specs — and
gives you assertion verbs over that, so process rules become tests that fail
in the same CI run, on the same commit, as everything else.

## Installation

```elixir
def deps do
  [
    {:assert_commit, "~> 0.1.0", only: :test}
  ]
end
```

## Usage

```elixir
defmodule MyApp.CommitTest do
  use ExUnit.Case, async: true
  use AssertCommit

  test "added controllers and LiveViews are routed", %{commit: commit} do
    assert_routed(commit)
  end

  test "migrations are ordered, immutable, and safe", %{commit: commit} do
    assert_migrations_ordered(commit)
    assert_migrations_immutable(commit)
    assert_indexes_concurrent(commit)
  end

  test "schema columns ship with their migration", %{commit: commit} do
    assert_schema_changes_migrated(commit)
  end

  test "new processes are supervised and new modules are tested", %{commit: commit} do
    assert_supervised(commit)
    assert_tested(commit)
  end

  test "the public API is documented, typed, and deprecated before removal", %{commit: commit} do
    assert_api_changes_logged(commit)
    assert_specs(commit)
    assert_moduledoc(commit)
    assert_removals_deprecated(commit)
  end

  test "moves are their own commit and behaviour changes are tested", %{commit: commit} do
    assert_pure_move(commit)
    assert_behaviour_changes_tested(commit)
  end

  test "housekeeping", %{commit: commit} do
    assert_lock_in_sync(commit)
    assert_release_logged(commit)
    refute_added_lines(commit, ~r/\b(IO\.inspect|dbg|IEx\.pry)\(/, in: ~r{^lib/})
  end
end
```

None of those rules names a module or a path. `use AssertCommit` imports the
verbs and query helpers, loads the change set once, injects it as
`%{commit: commit}`, and tags the module `:assert_commit` so `mix test --exclude assert_commit`
skips it where there is no meaningful `HEAD`.

## How it works

Three layers, each built on the one below and all read-only — source is
parsed with `Code.string_to_quoted/2` and never compiled, so every layer works
on any revision, whether or not its dependencies are available.

1. **Facts** (`AssertCommit.Source.Facts`) — per file: modules, their `use`s
   and attributes, functions with arity, visibility, `@spec`/`@doc`/`@deprecated`,
   struct fields, and referenced modules with aliases resolved.
2. **Diff** (`AssertCommit.Source.Diff`) — set difference over facts: modules
   added, removed, *renamed* (same public surface under a new name), and
   modified; functions added, removed, body-changed, spec-changed. This is how
   `assert_pure_move/1` knows a move is pure and `behaviour_changed?/1` knows a
   doc edit is not.
3. **Adapters** (`AssertCommit.Adapters.*`) — library-aware models of a module:

   | Adapter | Recognises | Model |
   |---|---|---|
   | `PhoenixRouter` | `use Phoenix.Router`, `use X, :router` | routes with plug modules resolved through `scope` aliasing |
   | `PhoenixHandler` | `use X, :controller` / `:live_view` / … | routable modules |
   | `EctoSchema` | `use Ecto.Schema` | source, fields, associations, expected columns |
   | `EctoMigration` | `use Ecto.Migration` | operations (`create table`, `alter table`, `create index`, `execute`, …), version, reversibility |
   | `OtpProcess` | `use GenServer` / `Supervisor` / `Application` / … | kind and child specs started |
   | `ExUnitCase` | `use ExUnit.Case`, `use *Case` | subject module, tests |

   Plus `AssertCommit.MixFile` (deps, version, lockfile) and `AssertCommit.Changelog`.

The verbs cross those models: `assert_routed/1` is "every added `PhoenixHandler`
is a plug of some `PhoenixRouter` in the resulting tree"; `assert_schema_changes_migrated/1`
is "every column an `EctoSchema` gained is added to its table by an added `EctoMigration`".
That is why they hold whether the route was wired in this commit or an earlier
one, and fail when the router was edited without adding the route.

Adapters implement the `AssertCommit.Adapter` behaviour (`recognize?/1`,
`extract/1`) over a module's facts, so a project can add its own for
libraries these do not cover.

## What you can assert on

- **Phoenix** — `assert_routed`, `routes_added`, `routes_removed`
- **Ecto** — `assert_migrations_ordered`, `assert_migrations_immutable`,
  `assert_schema_changes_migrated`, `assert_indexes_concurrent`,
  `assert_migrations_reversible`, `migrations_added`, `migrations`
- **OTP** — `assert_supervised`
- **ExUnit** — `assert_tested`, `assert_behaviour_changes_tested`
- **Mix / Changelog** — `assert_lock_in_sync`, `assert_release_logged`,
  `assert_api_changes_logged`, `deps_added`, `deps_removed`, `version_bump`
- **Elixir source** — `assert_specs`, `assert_moduledoc`, `assert_removals_deprecated`,
  `assert_pure_move`, `assert_references`; queries `modules_added`, `modules_renamed`,
  `functions_added`, `public_api_diff`, `behaviour_changed?`, `elixir_diff`
- **Files and lines** — `assert_added`, `refute_added`, `assert_modified`,
  `refute_modified`, `assert_removed`, `refute_removed`, `assert_touched`,
  `refute_touched`, `assert_immutable`, `assert_coupled`, `assert_counterpart`,
  `assert_exists`, `assert_last_by_name`, `refute_added_lines`, `formatting_only?`
- **Message** — `assert_subject`, `refute_subject`, `assert_message`,
  `assert_trailer`, `refute_trailer`, `assert_scope_matches_paths`
- **Shape** — `assert_max_files`, `assert_max_additions`

## Fixtures and the cookbook

`fixtures/` holds four fixture repositories as a `base/` tree plus one
`git format-patch` file per scenario:

```
fixtures/phoenix/scenarios/
  routed_controller.patch
  unrouted_controller.patch
  router_touched_not_wired.patch
  migration_rebased.patch
  ...
```

Each patch *is* the commit it reproduces — subject, trailers, and diff — so a
reviewer sees exactly what a scenario changes. `test/scenarios/` runs every verb
against them, passing and failing, and is the cookbook for adopting a rule:

```elixir
use AssertCommit, repo: & &1.repo, rev: &"scenario/#{&1.scenario}"

setup_all do: %{repo: AssertCommit.Fixtures.repo("phoenix")}

@tag scenario: :unrouted_controller
test "fails when no router was touched", %{commit: commit} do
  error = assert_raise ExUnit.AssertionError, fn -> assert_routed(commit) end
  assert error.message =~ "no router routes to them"
end
```

Options to `use AssertCommit` may be functions of the test context, evaluated
per test — that is how one policy module runs against many pinned revisions.

## Change sources

| `use AssertCommit, ...`     | Loads                                   | Message |
|-----------------------------|-----------------------------------------|---------|
| (default)                   | `HEAD` of the current directory         | yes     |
| `rev: "abc123"`             | any revision                            | yes     |
| `source: :staged`           | the index, against `HEAD`               | no      |
| `repo: "../other"`          | another repository                      | —       |

`AssertCommit.Commit.new/1` builds a synthetic change set from in-memory
trees, for unit-testing rules and adapters without git. Message assertions on
a `:staged` change set raise `AssertCommit.NoMessageError`; guard them with
`has_message?/1`.

## In CI

A depth-1 checkout has `HEAD` but not its parent, so nothing can be diffed:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 2
```

On `pull_request` events GitHub checks out a synthetic merge commit. assert_commit
refuses merge commits (`AssertCommit.MergeCommitError`) rather than silently
diffing against one parent. To gate every commit in a PR:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
- run: |
    for sha in $(git rev-list --reverse ${{ github.event.pull_request.base.sha }}..${{ github.event.pull_request.head.sha }}); do
      git checkout -q "$sha" && mix test test/commit_test.exs || exit 1
    done
```

## Limits

Adapters recognise conventional shapes, not macro semantics. `use MyAppWeb, :controller`
is a convention; a controller defined some other way is invisible to
`assert_routed/1` and the rule passes vacuously for it. Each adapter's
documentation lists the shapes it understands.

## License

MIT
