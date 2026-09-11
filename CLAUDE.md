# assert_commit

ExUnit assertions over the shape and contents of git commits.

## What it does

Loads a change set (a commit, the staged index, or an in-memory synthetic
one) into an `AssertCommit.Commit`, parses the Elixir it changed into a
structural diff and library-aware models, and provides assertion verbs so
that process rules ("controllers are routed", "schema columns ship with a
migration", "moves are their own commit") run as tests on every commit.

## Architecture

Layers, bottom up. Each depends only on the ones below it.

- `AssertCommit.Git` — the only module that shells out. Plumbing only, global/system config ignored. `System.cmd` cannot close stdin, so never use `--stdin` (`hash-object -t tree /dev/null` for the empty tree).
- `AssertCommit.Tree`, `FileChange`, `Hunk`, `Message`, `Commit` — trees are a path set plus a reader closure (git- or map-backed); hunks come from `List.myers_difference/2` over blob contents so synthetic and git commits diff identically. `Commit` computes `elixir: Source.Diff.t()` at load.
- `AssertCommit.Source.Facts` — per-file structural facts from `Code.string_to_quoted/2` (never compiles): modules, `use`s, attributes, functions (arity, kind, spec/doc/deprecated, clause hashes), struct fields, references with aliases resolved. Memoised in `:persistent_term` per `{tree_oid, path}`.
- `AssertCommit.Source.Diff` — set difference over facts; detects module renames by equal non-trivial surface or by git file rename. `behaviour_changed?/1` is the trigger for "code change needs test change" and is false for docs/formatting.
- `AssertCommit.Source.Index` — tree-wide discovery for after-tree invariants. `AssertCommit.Source` — `diff/1`, `models/2`, `find/3`.
- `AssertCommit.Adapter` + `AssertCommit.Adapters.*` — `recognize?/1` and `extract/1` over a `Facts.Module`; one domain struct per library. `PhoenixRouter` reproduces Phoenix's scope-alias concatenation exactly (including the `alias X` + `scope "/", X` footgun).
- `AssertCommit.MixFile`, `AssertCommit.Changelog` — file-level parsers for `mix.exs`/`mix.lock` and `CHANGELOG.md`.
- `AssertCommit.Query` — data-returning helpers. `AssertCommit.Assertions` (files, lines, generic Elixir, message, shape) and `AssertCommit.Assertions.{Phoenix, Ecto, OTP, ExUnit, Mix, Changelog}` — verbs that `Flunk.flunk/1` with actionable messages. `AssertCommit.__using__/1` imports all of them; options that are functions of the test context switch it from `setup_all` to `setup`.

Design rule: prefer after-tree invariants triggered by diff predicates over diff-only coupling. `assert_routed/1` checks routers in the resulting tree; `assert_coupled/3` on paths is the escape hatch, not the model.

## Fixtures

`fixtures/<family>/base/` is a tree; `fixtures/<family>/scenarios/<name>.patch` is `git format-patch -1 -k -M --binary --no-signature` output. `AssertCommit.Fixtures.build!/2` inits a repo, commits the base on `main`, and `git am -3 -k`s each patch onto `scenario/<name>`; `Fixtures.repo/1` does that once per test module under `tmp/`. Patches are the reviewable truth for what a scenario changes — add a scenario by committing on the base and running format-patch, never by editing a patch's hunks by hand. `.gitattributes`/`.editorconfig` keep editors from stripping their trailing whitespace. Fixtures live at the project root so `mix test`, the formatter, and credo do not see the fixture apps' own files.

## Development commands

```bash
mix test                      # run all tests (dogfood tests need HEAD~1)
mix format                    # format code
mix format --check-formatted  # check formatting
mix credo --strict            # lint
mix dialyzer                  # static analysis
```

## Testing conventions

- Unit tests mirror `lib/` in `test/assert_commit/`; adapters are tested from source strings via `Facts.from_source/2`.
- `test/scenarios/*_test.exs` are the cookbook: `use AssertCommit, repo: & &1.repo, rev: &"scenario/#{&1.scenario}"`, one `@tag scenario:` per test, every verb shown passing and failing, and no module or path names in the rules — derive any name a failure message needs from a query on the commit.
- `test/assert_commit_dogfood_test.exs` runs `use AssertCommit` on this repository's own `HEAD`; excluded by `test_helper.exs` when `HEAD~1` is unavailable.
- Property tests: `Hunk.diff/2` reconstructs the after text; message trailers round-trip.

## Gotchas

- `git am` strips `[bracketed]` subject prefixes unless `-k`; patches are generated with `-k` and have no `[PATCH]` prefix.
- Shallow-clone boundary commits report no parents; `Git.shallow_boundary?/2` tells them from root commits.
- `Code.string_to_quoted/2` warns on `mix.lock`'s quoted keywords; `MixFile` passes `emit_warnings: false`.
- `assert_raise/3` with a regex matches `Exception.message/1`, which re-indents `ExUnit.AssertionError`; pin failure text via `error.message`.
- `AssertCommit.Source` cannot be named `AssertCommit.Elixir` — `alias`ing it as `Elixir` collides with the root namespace.
- `setup_all` does not get a `tmp_dir`; use `Fixtures.repo/1`.

## Commit message style

```
[component] brief description

Optional longer explanation.
```

## Changelog

Every user-visible change must have an entry in `CHANGELOG.md` under an `## Unreleased` section at the top.
