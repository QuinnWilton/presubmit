# assert_commit

[![CI](https://github.com/QuinnWilton/assert_commit/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/assert_commit/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/assert_commit.svg)](https://hex.pm/packages/assert_commit)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/assert_commit)

A linter for git commits: rules over the shape and contents of a change,
with Elixir-aware models of what changed.

A test suite proves that the code at `HEAD` works. It says nothing about
whether the *commit* is one your process would accept: whether the migration
it adds will run in order, whether the controller it adds is reachable, whether
the public function it removes was ever deprecated, whether a move was landed
on its own. `mix assert_commit` loads a change set — a commit, the staged
index, or the working tree — parses the Elixir it changed into a structural
description (modules, functions, schema fields, routes, child specs), and runs
your rules against it. Nothing is compiled, so it runs in well under a second
and on any revision.

## Installation

```elixir
def deps do
  [
    {:assert_commit, "~> 0.1.0", only: [:dev, :test], runtime: false}
  ]
end
```

## Usage

```
$ mix assert_commit
Examining working tree (1 file differs from HEAD)

  ✓ new public functions have a @spec
  ✗ added controllers and LiveViews are routed
      These controllers were added but no router routes to them:
        DemoWeb.PostController (controller)

      Routers checked: DemoWeb.Router
  ✓ added migrations are newer than every existing one
  - subject fits the configured length (skipped: needs a commit message; the change set was built from :worktree)
  ...

26 rules: 22 passed, 1 failed, 3 skipped
```

```
mix assert_commit                     # working tree if anything differs from HEAD, else HEAD
mix assert_commit --head              # the commit at HEAD
mix assert_commit --rev abc123        # any revision
mix assert_commit --staged            # the index — from a pre-commit hook
mix assert_commit --worktree          # the working directory — from an editor or agent loop
mix assert_commit --range main..HEAD  # every non-merge commit on a branch, oldest first
mix assert_commit --format json
mix assert_commit --list              # the configured rule sets and rules
```

The first line always names what was examined, so a green run on a dirty
tree can never be mistaken for a green commit. Exit status is 0 when every
rule passed or was skipped, 1 when any failed, 2 on a usage or configuration
error.

## Configuration

`.assert_commit.exs` evaluates to a list of rule sets. Without one, every
built-in set runs with its defaults.

```elixir
[
  AssertCommit.Rules.Elixir,
  AssertCommit.Rules.Phoenix,
  {AssertCommit.Rules.Ecto, except: [:migrations_reversible]},
  AssertCommit.Rules.OTP,
  {AssertCommit.Rules.ExUnit, only: [:behaviour_changes_tested]},
  AssertCommit.Rules.Mix,
  AssertCommit.Rules.Changelog,
  {AssertCommit.Rules.Message,
   subject: ~r/^\[[a-z_-]+\] /,
   scope: {~r/^\[(\w+)\]/, fn component -> ~r{^#{component}/} end},
   trailers: [{&MyApp.CommitRules.llm_assisted?/1, "Claude-Session", ~r{^https://}}]},
  {AssertCommit.Rules.Hygiene, debug: ~r/\b(IO\.inspect|dbg|IEx\.pry)\(/},
  {AssertCommit.Rules.Shape, max_files: 40},
  MyApp.CommitRules
]
```

### Built-in rule sets

| Set | Rules |
|---|---|
| `Rules.Elixir` | `specs`, `moduledoc`, `removals_deprecated`, `pure_move` |
| `Rules.Phoenix` | `routed` — every added controller/LiveView is a plug of some router |
| `Rules.Ecto` | `migrations_ordered`, `migrations_immutable`, `schema_changes_migrated`, `indexes_concurrent`, `migrations_reversible` |
| `Rules.OTP` | `supervised` — every added GenServer/Agent/Task/Supervisor is started somewhere |
| `Rules.ExUnit` | `tested`, `behaviour_changes_tested` |
| `Rules.Mix` | `lock_in_sync` |
| `Rules.Changelog` | `api_changes_logged`, `release_logged` |
| `Rules.Message` | `no_fixup`, `subject_length`, `subject`, `scope`, `trailers` |
| `Rules.Hygiene` | `no_debug_calls`, `no_merge_markers`, `no_artifacts` |
| `Rules.Shape` | `max_files`, `max_additions` |

### Writing rules

A rule set is a module; a rule is a function of the commit that returns `:ok`
or raises `AssertCommit.Violation`. The assertion verbs do the raising, with
messages that name what is wrong and what would fix it. Rule sets can be
defined inline in `.assert_commit.exs`.

```elixir
defmodule MyApp.CommitRules do
  use AssertCommit.RuleSet

  import AssertCommit.Query
  import AssertCommit.Assertions
  import AssertCommit.Assertions.Mix

  rule :release_only, "a version bump touches only release metadata", fn commit ->
    if version_bump(commit), do: refute_touched(commit, ~r{^(lib|test)/}), else: :ok
  end

  rule :manifest_by_tooling, "the tooling manifest is only changed with its trailer", fn commit ->
    if touches?(commit, ~r{^\.tooling/}), do: assert_trailer(commit, "Tooling"), else: :ok
  end

  rule :issue_refs, "TODOs reference an issue", fn commit, opts ->
    refute_added_lines(commit, Keyword.get(opts, :todo, ~r/TODO(?!\(#\d+\))/), in: ~r{^lib/})
  end
end
```

Rules take two arguments to read the set's options. Return `{:skip, reason}`
for a rule that has nothing to check; message rules skip automatically when
the change set has no message.

## How it works

Three read-only layers — source is parsed with `Code.string_to_quoted/2` and
never compiled:

1. **Facts** (`AssertCommit.Source.Facts`) — per file: modules, their `use`s
   and attributes, functions with arity, visibility, `@spec`/`@doc`/`@deprecated`/`@impl`,
   struct fields, and referenced modules with aliases resolved.
2. **Diff** (`AssertCommit.Source.Diff`) — modules added, removed, *renamed*
   (same public surface under a new name, or a git rename), and modified;
   functions added, removed, body-changed, spec-changed. `behaviour_changed?/1`
   is false for docs-only and formatting-only commits.
3. **Adapters** (`AssertCommit.Adapters.*`) — library-aware models of a module:

   | Adapter | Recognises | Model |
   |---|---|---|
   | `PhoenixRouter` | `use Phoenix.Router`, `use X, :router` | routes with plug modules resolved through `scope` aliasing |
   | `PhoenixHandler` | `use X, :controller` / `:live_view` / … | routable modules |
   | `EctoSchema` | `use Ecto.Schema` | source, fields, associations, expected columns |
   | `EctoMigration` | `use Ecto.Migration` | operations, version, reversibility |
   | `OtpProcess` | `use GenServer` / `Supervisor` / `Application` / … | kind and child specs started |
   | `ExUnitCase` | `use ExUnit.Case`, `use *Case` | subject module, tests |

   Plus `AssertCommit.MixFile` (deps, version, lockfile) and `AssertCommit.Changelog`.

The verbs cross those models: `assert_routed/1` is "every added `PhoenixHandler`
is a plug of some `PhoenixRouter` in the resulting tree"; `assert_schema_changes_migrated/1`
is "every column an `EctoSchema` gained is added to its table by an added
`EctoMigration`". They hold whether the route was wired in this commit or an
earlier one, and fail when the router was edited without adding the route.
Adapters implement `AssertCommit.Adapter` over a module's facts, so a project
can add its own.

### Verbs

- **Phoenix / Ecto / OTP / ExUnit / Mix / Changelog** — `assert_routed`,
  `assert_migrations_ordered`, `assert_migrations_immutable`,
  `assert_schema_changes_migrated`, `assert_indexes_concurrent`,
  `assert_migrations_reversible`, `assert_supervised`, `assert_tested`,
  `assert_behaviour_changes_tested`, `assert_lock_in_sync`,
  `assert_release_logged`, `assert_api_changes_logged`.
- **Elixir source** — `assert_specs`, `assert_moduledoc`, `assert_removals_deprecated`,
  `assert_pure_move`, `assert_references`.
- **Files and lines** — `assert_added`/`refute_added` and friends, `assert_immutable`,
  `assert_coupled`, `assert_counterpart`, `assert_exists`, `assert_last_by_name`,
  `refute_added_lines`.
- **Message** — `assert_subject`, `refute_subject`, `assert_message`,
  `assert_trailer`, `refute_trailer`, `assert_scope_matches_paths`.
- **Shape** — `assert_max_files`, `assert_max_additions`.
- **Queries** (`AssertCommit.Query`) — `added`, `modified`, `renamed`, `touched`,
  `added_lines`, `modules_added`, `modules_renamed`, `public_api_diff`,
  `behaviour_changed?`, `formatting_only?`, `trailers`, `elixir_diff`, …

## In CI and hooks

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 2          # HEAD's parent must be present
- run: mix assert_commit --head
```

On `pull_request` events GitHub checks out a synthetic merge commit; assert_commit
refuses merge commits rather than diffing against one parent. To gate every
commit in a PR, use `fetch-depth: 0` and
`mix assert_commit --range ${{ github.event.pull_request.base.sha }}..${{ github.event.pull_request.head.sha }}`.

Examining a dirty working tree under `CI` prints a warning — it almost always
means a build step modified the checkout — but does not change the source.

A pre-commit hook is `mix assert_commit --staged`; an editor or agent loop is
`mix assert_commit --worktree` (or just `mix assert_commit`).

## Fixtures and the cookbook

`fixtures/` holds four fixture repositories as a `base/` tree plus one
`git format-patch` file per scenario. Each patch *is* the commit it reproduces
— subject, trailers, and diff — so a reviewer sees exactly what a scenario
changes. `test/scenarios/` runs every rule against them, passing and failing,
and is the cookbook for adopting a rule.

## Limits

Adapters recognise conventional shapes, not macro semantics. `use MyAppWeb, :controller`
is a convention; a controller defined some other way is invisible to
`assert_routed/1`, and the rule passes vacuously for it. Each adapter's
documentation lists the shapes it understands.

## License

MIT
