# presubmit

[![CI](https://github.com/QuinnWilton/presubmit/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/presubmit/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/presubmit.svg)](https://hex.pm/packages/presubmit)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/presubmit)

A linter for git commits, with Elixir-aware models of what changed. The
name is borrowed from Chromium's `PRESUBMIT.py` checks — the same idea,
applied per commit and with Elixir semantics.

Your tests prove that the code at `HEAD` works. They say nothing about
whether the *commit* is one your process would accept: whether the migration
it adds will run in order, whether the controller it adds is reachable,
whether the function it removes was ever deprecated, whether a move was
landed on its own. presubmit checks those. It parses the Elixir a change
touched into modules, functions, schema fields, routes, and child specs — never
compiling anything — and runs rules over that, on the commit, the staged
index, or the working tree. A commit of the Elixir compiler's repository
(330 source files) checks in under two seconds; a 300-commit range in about
a minute.

```
$ mix presubmit
Examining staged index (2 files differ from HEAD) — Add posts index

  ✗ added controllers and LiveViews are routed
      These controllers were added but no router routes to them:
        DemoWeb.PostController (controller)

      Routers checked: DemoWeb.Router
  ✓ added migrations are newer than every existing one
  ✓ schema columns are added by a migration in the same commit
  ✓ a commit that renames files contains nothing else
  ...

17 rules: 16 passed, 1 failed
```

The rules are invariants on the tree the change *produces*, triggered by
what the change touched. "A controller was added ⇒ some router routes to it"
holds whether the route was wired in this commit or an earlier one, and
fails when the router was edited without adding the route.

## Setup

```elixir
# mix.exs
{:presubmit, "~> 0.1.0", only: [:dev, :test], runtime: false}
```

```sh
mix presubmit.install     # commit-msg hook: checks staged changes + message before each commit
mix presubmit             # run it by hand; picks the working tree if dirty, else HEAD
```

Add `import_deps: [:presubmit]` to `.formatter.exs` so `mix format`
leaves `rule :id, "name", fn … end` declarations without parentheses. The
first run after `mix deps.get` compiles the dependency, so the first hooked
commit in a fresh clone is slower than the rest.

The `commit-msg` hook runs `mix presubmit --staged --message-file "$1"`,
so every rule — message rules included — runs before the commit exists. A
companion `prepare-commit-msg` hook notices `git commit --amend` and has the
amended commit checked (`HEAD^` to the index) instead of the delta since
`HEAD`, which could never satisfy a rule whose other half is in the original
commit (git does not report an amend combined with `-m`/`-F`; use the
editor or `--no-edit`, or `mix presubmit --staged --base HEAD^`). Add `--pre-commit` for an earlier content-only pass before the editor
opens; `--uninstall` removes them all. The hooks step aside with a note
while a merge is in progress, when amending a merge, and when `mix` is not
on `PATH` (GUI clients often lack your shell environment); a rule that
crashes is reported but does not block. Run the installer from the project
directory — in a subdirectory project of a larger repository the hooks `cd`
there first. Hooks are per clone and `git commit --no-verify` skips them
(the right answer for an initial import, once), so CI is the backstop:

```yaml
# .github/workflows/ci.yml
commits:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0                # every commit in a PR is checked individually
    - uses: erlef/setup-beam@v1
      with: { elixir-version: "1.19", otp-version: "28" }
    - run: mix deps.get
    - if: github.event_name == 'pull_request'
      run: mix presubmit --range ${{ github.event.pull_request.base.sha }}..${{ github.event.pull_request.head.sha }}
    - if: github.event_name == 'push'
      run: mix presubmit --range ${{ github.event.before }}..${{ github.sha }}   # --head for a new branch
```

On `pull_request` events `HEAD` is a synthetic merge commit, which
presubmit refuses rather than diffing against one parent; `--range`
checks the PR's own commits, oldest first. Exit status is 0 when every rule
passed or was skipped, 1 on any failure, 2 on a usage or configuration error.
The first line of output always names what was examined.

## Configuration

Without a `.presubmit.exs`, the defaults are the rules that do not fail
an ordinary commit — calibrated against this workspace's projects and the
Elixir repository's history — and they adapt to the project: Phoenix and
Ecto rules when those libraries are loaded or are dependencies, the release
changelog rule when there is a `CHANGELOG.md`. The output says what was
enabled and why.

The rules that encode a *policy* — `specs` (every new public function
typed), `removals_deprecated` (deprecate before removing), `api_changes_logged`
(a changelog entry per API change), `behaviour_changes_tested` (tests move
with code) — run as **warnings** by default: on real histories they fire on
15–40% of otherwise reasonable commits, so they are shown but do not block.
`--warnings-as-errors` promotes them in CI; `warn:` in the config chooses
per rule; `tested` is opt-in. The file is a list of rule sets and replaces
the defaults:

```elixir
# .presubmit.exs
[
  Presubmit.Rules.Elixir,
  Presubmit.Rules.Phoenix,
  {Presubmit.Rules.Ecto, except: [:migrations_reversible]},
  {Presubmit.Rules.ExUnit, only: [:behaviour_changes_tested]},
  Presubmit.Rules.Mix,
  Presubmit.Rules.Changelog,
  Presubmit.Rules.Hygiene,
  {Presubmit.Rules.Shape, max_files: 40},
  {Presubmit.Rules.ExUnit, only: [:behaviour_changes_tested], in: ~r{^apps/core/}},   # scoped to a path
  {Presubmit.Rules.Message,
   subject: ~r/^\[[a-z_-]+\] /,
   scope: {~r/^\[(\w+)\]/, fn component -> ~r{^#{component}/} end}},
  MyApp.CommitRules
]
```

| Set | Rules |
|---|---|
| `Elixir` | `specs`, `moduledoc`, `removals_deprecated`, `pure_move` |
| `Phoenix` | `routed` |
| `Ecto` | `migrations_ordered`, `migrations_immutable`, `schema_changes_migrated`, `indexes_concurrent`, `migrations_reversible` |
| `OTP` | `supervised` |
| `ExUnit` | `tested`, `behaviour_changes_tested` |
| `Mix` | `lock_in_sync` |
| `Changelog` | `api_changes_logged`, `release_logged` |
| `Message` | `no_fixup`, `subject_length`, `subject`, `scope`, `trailers` |
| `Hygiene` | `no_debug_calls`, `no_merge_markers`, `no_artifacts` |
| `Shape` | `max_files`, `max_additions` |

Every set takes `only:`/`except:` to select rules, `warn:` to make some of
them non-blocking, and `in:` to restrict the set to changes under a path
pattern (a rule set with no changes in scope is skipped).

A commit can exempt itself, as in Chromium: a `Presubmit-Skip: pure_move, max_files`
trailer skips the named rules and `No-Presubmit: true` skips them all. Both
are announced on every run and are part of the commit, so CI sees the same
decision — prefer them to `git commit --no-verify`, which leaves no trace.
`mix presubmit --list` prints the configured rules with their descriptions.

### Your own rules

A rule is a function of the change set that returns `:ok` or raises
`Presubmit.Violation`; the assertion verbs in `Presubmit.Assertions`
and `Presubmit.Assertions.{Phoenix,Ecto,OTP,ExUnit,Mix,Changelog}` do the
raising with messages that say what is wrong and how to fix it. Rule sets
can live in `.presubmit.exs` itself.

```elixir
defmodule MyApp.CommitRules do
  use Presubmit.RuleSet

  import Presubmit.Query
  import Presubmit.Assertions
  import Presubmit.Assertions.Mix

  rule :release_only, "a version bump touches only release metadata", fn commit ->
    if version_bump(commit), do: refute_touched(commit, ~r{^(lib|test)/}), else: :ok
  end

  rule :manifest_by_tooling, "the tooling manifest only changes with its trailer", fn commit ->
    if touches?(commit, ~r{^\.tooling/}), do: assert_trailer(commit, "Tooling"), else: :ok
  end
end
```

Queries (`added/2`, `modules_added/2`, `public_api_diff/1`, `behaviour_changed?/2`,
`trailer/2`, …) return data; a check that has nothing configured returns
`{:skip, reason}`. The scenario suites under `test/scenarios/` show every
built-in rule passing and failing against the fixture repositories in
`fixtures/`, where each scenario is a `git format-patch` file — the commit it
reproduces, readable as such.

## Sources

| Flag | Examines |
|---|---|
| *(none)* | the working tree if anything differs from `HEAD`, else `HEAD` |
| `--head`, `--rev REV` | a commit |
| `--staged [--message-file F] [--base REV]` | the index against `HEAD` (or `REV`), optionally with the message being written |
| `--worktree` | everything on disk against `HEAD` |
| `--range A..B` | each non-merge commit in the range |

`--format json` for tooling. Under `CI`, examining a dirty working tree
prints a warning rather than silently checking the wrong thing.

## Limits

Adapters recognise conventional shapes (`use MyAppWeb, :controller`,
`use Ecto.Schema`, `children = [...]`), not macro semantics; functions,
routes, schemas, and child specs produced by macros are invisible, and a
rule that depends on them passes vacuously rather than failing. Each
adapter's documentation lists the shapes it understands; `--list` repeats
the warning. Where a convention is commonly bypassed on purpose the rules
know about it — `action_fallback` controllers, `DynamicSupervisor`
children, `virtual` fields, unmerged migrations (`Rules.Ecto` with
`since: "origin/main"`), `fixup!` commits, `Revert`/`Merge` subjects.

`.presubmit.exs` is evaluated as code, like `mix.exs` — and with
`--repo` it is the *other* repository's file that runs. Do not point
`--repo` at a checkout you would not run `mix` in; a CI job examining
untrusted pull-request checkouts should pass `--config` with its own file.

Umbrella and subdirectory projects work: directory patterns match at any
depth and every `mix.exs` is read. POSIX shells only for the hooks; Windows
is untested.

## License

MIT
