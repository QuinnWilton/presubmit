# assert_commit

A linter for git commits: rules over the shape and contents of a change, with Elixir-aware models of what changed. Run as `mix assert_commit`.

## What it does

Loads a change set (a commit, the staged index, the working tree, or an in-memory synthetic one) into an `AssertCommit.Commit`, parses the Elixir it changed into a structural diff and library-aware models, and runs rule sets from `.assert_commit.exs` against it, reporting each rule as passed, failed, or skipped.

## Architecture

Layers, bottom up. Each depends only on the ones below it.

- `AssertCommit.Git` — the only module that shells out. Plumbing only; the user's config is honoured (CI needs `safe.directory`) and every call passes the flags that keep output config-independent. `System.cmd` cannot close stdin, so never use `--stdin`. `write_worktree_tree/1` builds a tree from disk through a temporary index (`GIT_INDEX_FILE`) so the real index is never touched.
- `AssertCommit.Tree`, `FileChange`, `Hunk`, `Message`, `Commit` — trees are a path set plus a reader closure (git- or map-backed); hunks come from `List.myers_difference/2` over blob contents. `Commit.head/rev/staged/worktree/new` all produce the same struct and compute `elixir: Source.Diff.t()` at load. `AssertCommit.load/1` adds `source: :auto` (two-state: `:worktree` if `Git.dirty?/1`, else `:head`).
- `AssertCommit.Source.Facts` / `Diff` / `Index` — per-file structural facts (memoised by *blob* oid in a shared ETS table, so a range parses each file version once; bounded, `Facts.clear_cache/0`), set-difference diff with rename detection, tree-wide discovery. Trees carry `blobs` (path → blob oid) and `repo`; `Tree.prefetch/2` bulk-reads paths with one `git archive` — anything about to read many files must prefetch, because per-file `cat-file` spawns dominated a 300-commit range (5.5 min → 1 min). `AssertCommit.Paths` holds the depth-agnostic directory patterns; never write `~r{^lib/}`. `Source.models/2` and `Source.find/3` apply adapters.
- `AssertCommit.Adapter` + `AssertCommit.Adapters.*` — `recognize?/1` and `extract/1` over a `Facts.Module`. `PhoenixRouter` reproduces Phoenix's scope-alias concatenation exactly.
- `AssertCommit.MixFile`, `AssertCommit.Changelog` — file-level parsers.
- `AssertCommit.Query` (data) and `AssertCommit.Assertions{,.Phoenix,.Ecto,.OTP,.ExUnit,.Mix,.Changelog}` (verbs that raise `AssertCommit.Violation` via `Assertions.Flunk`).
- `AssertCommit.Hooks` + `Mix.Tasks.AssertCommit.Install` — writes marker-tagged `prepare-commit-msg` + `commit-msg` (and optional `pre-commit`) hooks; never overwrites a foreign hook. `prepare-commit-msg` sees git's `commit` source with `HEAD`'s SHA on `--amend` and records `HEAD^` in `.git/assert_commit_base`; `commit-msg` turns that into `--base`, so the amended commit is checked, not the delta. `--message-file` attaches the message to `--staged` so message rules run in the hook (`Message.clean/1` strips comments and scissors as git does).
- `AssertCommit.Rule`, `RuleSet` (the `rule/3` DSL; `use AssertCommit.RuleSet, requires: [...]`; `applicable?/2`), `Rules.*` (built-in sets), `Config` (`.assert_commit.exs`, or `default/1` which enables sets whose `requires/0` hold — VM-loaded module, declared/locked dep, or file present — and records `detection`), `Runner` (`Report`/`Result`, `run_range/3`), `Formatter` (text/JSON; every rendering starts by naming the source), `CLI` (argument parsing, source selection, CI warning, exit status), `Mix.Tasks.AssertCommit`.

Design rules: after-tree invariants triggered by diff predicates, not diff-only coupling. Explicit sources; `:auto` only at the CLI, and always announced. Rules with nothing configured return `{:skip, reason}` rather than passing silently. Defaults must have a low false-positive rate on an ordinary project, and anything detection-dependent is announced in the output.

## Fixtures

`fixtures/<family>/base/` is a tree; `fixtures/<family>/scenarios/<name>.patch` is `git format-patch -1 -k -M --binary --no-signature` output. `AssertCommit.Fixtures.repo/1` builds a repo per test module with a `scenario/<name>` branch per patch. Patches are the reviewable truth — add a scenario by committing on the base and running format-patch. Fixtures live at the project root so `mix test`, the formatter, and credo ignore the fixture apps' own files.

## Development commands

```bash
mix assert_commit.install     # once per clone: commit-msg hook running this repo's own policy
mix test                      # run all tests (dogfood test needs HEAD~1)
mix assert_commit --head      # this repo's own commit policy against HEAD
mix format                    # format code
mix credo --strict            # lint
mix dialyzer                  # static analysis
```

## Testing conventions

- Unit tests mirror `lib/` in `test/assert_commit/`; adapters are tested from source strings via `Facts.from_source/2`; the CLI through `AssertCommit.CLI.main/2` with `ci:` injected.
- `test/scenarios/*_test.exs` are the cookbook: `run_rule(Rules.X, :id, scenario(repo, :name), opts)` via `AssertCommit.RuleHelpers`, every rule shown passing and failing, and no module or path names in the rules — derive any name a failure message needs from a query on the commit.
- `test/assert_commit_dogfood_test.exs` runs `.assert_commit.exs` against this repository's `HEAD`; excluded when `HEAD~1` is unavailable.
- Property tests: `Hunk.diff/2` reconstructs the after text; message trailers round-trip.

## Gotchas

- Module attributes cannot hold anonymous functions: `rule/3` generates a `__rule__/1` clause per rule, and tests keep rule lists in functions.
- `git am` strips `[bracketed]` subject prefixes unless `-k`.
- Shallow-clone boundary commits report no parents; `Git.shallow_boundary?/2` tells them from root commits.
- `Code.string_to_quoted/2` warns on `mix.lock`'s quoted keywords; `MixFile` passes `emit_warnings: false`.
- The formatter parenthesises `rule`/`assert_pass`/`assert_fail` unless `.formatter.exs` lists them in `locals_without_parens`, and does not remove parens it already added.
- `setup_all` does not get a `tmp_dir`; use `Fixtures.repo/1`.
- Never `git reset --hard` with uncommitted work in the tree; a refused hook means the commit did not happen, so `HEAD~1` is the previous real commit. Stash or commit first.
- Dialyzer rejects `MapSet.t()` inside a map type in a `@spec` (opaque subterm); `RuleSet.env()` uses plain lists.
- Map key order is not stable across OTP versions; `AssertCommit.JSON` sorts keys.
- macOS temp dirs are symlinks (`/var` → `/private/var`); compare paths by suffix in tests, and let git compute relative paths (`--show-prefix`).
- Rules that only make sense on a commit declare `sources: [:head, :rev]`; in a hook the change set is `:staged`.

## CI

`.github/workflows/ci.yml` has a `commits` job with `fetch-depth: 0`: pull requests run `mix assert_commit --range base..head` (HEAD on a PR is a synthetic merge commit, which the tool refuses), pushes run `--range before..sha` (`--head` when `before` is the all-zeros SHA of a new branch).

## Commit message style

```
[component] brief description

Optional longer explanation.
```

## Changelog

Every user-visible change must have an entry in `CHANGELOG.md` under an `## Unreleased` section at the top.
