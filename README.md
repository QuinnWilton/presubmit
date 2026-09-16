# presubmit

[![CI](https://github.com/QuinnWilton/presubmit/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/presubmit/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/presubmit.svg)](https://hex.pm/packages/presubmit)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/presubmit)

A linter for git commits. It checks the commit, the staged index, or the
working tree against rules that understand Elixir, such as "an added
controller is routed", "an added migration sorts last", and "a move contains
nothing but the move".

The idea and the name come from Chromium's [`PRESUBMIT.py`](https://www.chromium.org/developers/how-tos/depottools/presubmit-scripts/).

## Setup

```elixir
# mix.exs
{:presubmit, "~> 0.1.0", only: [:dev, :test], runtime: false}
```

```sh
mix presubmit.install   # commit-msg hook: checks each commit (staged changes + message) before it exists
mix presubmit           # by hand: the working tree if dirty, else HEAD
mix presubmit --list    # what is configured
```

Add `import_deps: [:presubmit]` to `.formatter.exs`. In CI, check every
commit (`HEAD` on a pull request is a synthetic merge, so use the range):

```yaml
- uses: actions/checkout@v4
  with: { fetch-depth: 0 }
- run: mix presubmit --range ${{ github.event.pull_request.base.sha }}..${{ github.event.pull_request.head.sha }}
```

`mix presubmit --help` lists the sources (`--head`, `--rev`, `--staged`,
`--worktree`, `--range`) and options (`--format json`, `--warnings-as-errors`).

## Configuration

Without `.presubmit.exs` the defaults apply: every rule that does not fail an
ordinary commit, plus the Phoenix and Ecto sets when those libraries are
present, with the opinionated rules as warnings. The output says what was
enabled and why. To choose, the file is a list of rule sets:

```elixir
[
  Presubmit.Rules.Elixir,
  {Presubmit.Rules.Ecto, except: [:migrations_reversible], since: "origin/main"},
  {Presubmit.Rules.ExUnit, only: [:behaviour_changes_tested], warn: [:behaviour_changes_tested]},
  {Presubmit.Rules.Message, subject: ~r/^\[[a-z_-]+\] /},
  {Presubmit.Rules.Shape, in: ~r{^apps/core/}},
  MyApp.CommitRules
]
```

Each entry takes `only:`/`except:` to select rules, `warn:` to report without
failing, `in:` to restrict the set to changes under a path, and the set's own
options. A commit can exempt itself with a `Presubmit-Skip: rule, rule` or
`No-Presubmit: true` trailer, which is announced on every run.

## Rules

Each set documents its rules and options:

- [`Presubmit.Rules.Elixir`](https://hexdocs.pm/presubmit/Presubmit.Rules.Elixir.html): specs, moduledocs, deprecation before removal, pure moves
- [`Presubmit.Rules.Phoenix`](https://hexdocs.pm/presubmit/Presubmit.Rules.Phoenix.html): added controllers and LiveViews are routed
- [`Presubmit.Rules.Ecto`](https://hexdocs.pm/presubmit/Presubmit.Rules.Ecto.html): migrations ordered, immutable, concurrent, reversible; schema columns migrated
- [`Presubmit.Rules.OTP`](https://hexdocs.pm/presubmit/Presubmit.Rules.OTP.html): added processes are supervised
- [`Presubmit.Rules.ExUnit`](https://hexdocs.pm/presubmit/Presubmit.Rules.ExUnit.html): tests move with code
- [`Presubmit.Rules.Mix`](https://hexdocs.pm/presubmit/Presubmit.Rules.Mix.html): `mix.lock` in sync
- [`Presubmit.Rules.Changelog`](https://hexdocs.pm/presubmit/Presubmit.Rules.Changelog.html): API changes and releases logged
- [`Presubmit.Rules.Message`](https://hexdocs.pm/presubmit/Presubmit.Rules.Message.html): subject shape, scope, trailers
- [`Presubmit.Rules.Hygiene`](https://hexdocs.pm/presubmit/Presubmit.Rules.Hygiene.html): no debug calls, conflict markers, or artifacts
- [`Presubmit.Rules.Shape`](https://hexdocs.pm/presubmit/Presubmit.Rules.Shape.html): size ceilings

Your own rules are a module with `use Presubmit.RuleSet` and `rule` declarations
over the verbs in [`Presubmit.Assertions`](https://hexdocs.pm/presubmit/Presubmit.Assertions.html)
and the queries in [`Presubmit.Query`](https://hexdocs.pm/presubmit/Presubmit.Query.html);
see [`Presubmit.RuleSet`](https://hexdocs.pm/presubmit/Presubmit.RuleSet.html).
Rules see source shapes, not macro output: what a macro generates is
invisible to them (see each adapter under `Presubmit.Adapters`).

## License

MIT
