# presubmit

A linter for git commits: rules over the shape and contents of a change, with Elixir-aware models of what changed. Run as `mix presubmit`.

## What it does

Loads a change set (a commit, the staged index, the working tree, or an in-memory synthetic one) into an `Presubmit.Commit`, parses the Elixir it changed into a structural diff and library-aware models, and runs rule sets from `.presubmit.exs` against it, reporting each rule as passed, failed, or skipped.

## Architecture

Layers, bottom up. Each depends only on the ones below it.

- `Presubmit.Git` — the only module that shells out. Plumbing only; the user's config is honoured (CI needs `safe.directory`) and every call passes the flags that keep output config-independent. `System.cmd` cannot close stdin, so never use `--stdin`. `write_worktree_tree/1` builds a tree from disk through a temporary index (`GIT_INDEX_FILE`) so the real index is never touched.
- `Presubmit.Tree`, `FileChange`, `Hunk`, `Message`, `Commit` — trees are a path set plus a reader closure (git- or map-backed); hunks come from `List.myers_difference/2` over blob contents. `Commit.head/rev/staged/worktree/new` all produce the same struct and compute `elixir: Source.Diff.t()` at load. `Presubmit.load/1` adds `source: :auto` (two-state: `:worktree` if `Git.dirty?/1`, else `:head`).
- `Presubmit.Source.Facts` / `Diff` / `Index` — per-file structural facts (memoised by `{blob oid, path}` in `Presubmit.Source.Cache`, a shared ETS table, so a range parses each file version once; bounded, `Facts.clear_cache/0`), set-difference diff with rename detection, tree-wide discovery. Trees carry `blobs` (path → blob oid) and `repo`; `Tree.prefetch/2` bulk-reads paths with one `git archive` — anything about to read many files must prefetch, because per-file `cat-file` spawns dominated a 300-commit range (5.5 min → 1 min). `Presubmit.Paths` holds the depth-agnostic directory patterns; never write `~r{^lib/}`. `Source.models/2` and `Source.find/3` apply adapters.
- `Presubmit.Adapter` + `Presubmit.Adapters.*` — `recognize?/1` and `extract/1` over a `Facts.Module`. `PhoenixRouter` reproduces Phoenix's scope-alias concatenation exactly.
- `Presubmit.MixFile`, `Presubmit.Changelog` — file-level parsers.
- `Presubmit.Query` (data) and `Presubmit.Assertions{,.Phoenix,.Ecto,.OTP,.ExUnit,.Mix,.Changelog}` (verbs that raise `Presubmit.Violation` via `Assertions.Flunk`).
- `Presubmit.Hooks` + `Mix.Tasks.Presubmit.Install` — writes marker-tagged `prepare-commit-msg` + `commit-msg` (and optional `pre-commit`) hooks; never overwrites a foreign hook. `prepare-commit-msg` sees git's `commit` source with `HEAD`'s SHA on `--amend` and records `HEAD^` in `.git/presubmit_base`; `commit-msg` turns that into `--base`, so the amended commit is checked, not the delta. `--message-file` attaches the message to `--staged` so message rules run in the hook (`Message.clean/1` strips comments and scissors as git does).
- `Presubmit.Rule`, `RuleSet` (the `rule/3` DSL; `use Presubmit.RuleSet, requires: [...]`; `applicable?/2`), `Rules.*` (built-in sets), `Config` (`.presubmit.exs`, or `default/1` which enables sets whose `requires/0` hold — VM-loaded module, declared/locked dep, or file present — and records `detection`), `Runner` (`Report`/`Result`, `run_range/3`; rules run in a linked, monitored worker with a per-rule timeout, deliberately plain `spawn_link` + `Process.monitor/1` so Concuerror can model it), `Formatter` (text/JSON; every rendering starts by naming the source), `CLI` (argument parsing, source selection, CI warning, exit status), `Mix.Tasks.Presubmit`.

Design rules: after-tree invariants triggered by diff predicates, not diff-only coupling. Explicit sources; `:auto` only at the CLI, and always announced. Rules with nothing configured return `{:skip, reason}` rather than passing silently. Defaults must have a low false-positive rate on an ordinary project, and anything detection-dependent is announced in the output.

## Fixtures

`fixtures/<family>/base/` is a tree; `fixtures/<family>/scenarios/<name>.patch` is `git format-patch -1 -k -M --binary --no-signature` output. `Presubmit.Fixtures.repo/1` builds a repo per test module with a `scenario/<name>` branch per patch. Patches are the reviewable truth — add a scenario by committing on the base and running format-patch. Fixtures live at the project root so `mix test`, the formatter, and credo ignore the fixture apps' own files.

## Development commands

```bash
mix presubmit.install     # once per clone: commit-msg hook running this repo's own policy
mix test                      # run all tests (dogfood test needs HEAD~1)
mix presubmit --head      # this repo's own commit policy against HEAD
mix format                    # format code
mix credo --strict            # lint
mix dialyzer                  # static analysis
```

## Testing conventions

- Unit tests mirror `lib/` in `test/presubmit/`; adapters are tested from source strings via `Facts.from_source/2`; the CLI through `Presubmit.CLI.main/2` with `ci:` injected.
- `test/scenarios/*_test.exs` are the cookbook: `run_rule(Rules.X, :id, scenario(repo, :name), opts)` via `Presubmit.RuleHelpers`, every rule shown passing and failing, and no module or path names in the rules — derive any name a failure message needs from a query on the commit.
- `test/presubmit_dogfood_test.exs` runs `.presubmit.exs` against this repository's `HEAD`; excluded when `HEAD~1` is unavailable.
- Property tests: `Hunk.diff/2` reconstructs the after text; message trailers round-trip. Stateful ones: `test/presubmit/commit_model_test.exs` applies random edit/stage/commit/amend sequences to a real repository and to three maps, then requires `Commit.rev/staged/worktree` to equal `Commit.new/1` over the maps (contents are unique per write so git can only pair identical blobs as renames); `test/presubmit/hooks_state_test.exs` drives the installed hook scripts against a model of the `.git/presubmit_base` handshake with a fake `mix` on `PATH` recording its argv.
- Concuerror: `MIX_ENV=test mix run --no-start test/concuerror/run.exs` model-checks `Presubmit.Source.Cache` and the runner's worker/timeout protocol exhaustively (scenarios in `test/support/concuerror/`, reports in `_build/concuerror/`). CI runs it. `test/presubmit/oracle_properties_test.exs` uses git as the oracle (`interpret-trailers --parse`, `stripspace --strip-comments`, `diff --numstat`); note git's xdiff is not a minimal edit script even with `--minimal`, so only line deltas and script length bounds are compared. `git stripspace` reads stdin only, so the test goes through `sh -c` with a file redirect.

## Gotchas

- Module attributes cannot hold anonymous functions: `rule/3` generates a `__rule__/1` clause per rule, and tests keep rule lists in functions.
- `git am` strips `[bracketed]` subject prefixes unless `-k`.
- Shallow-clone boundary commits report no parents; `Git.shallow_boundary?/2` tells them from root commits.
- `Code.string_to_quoted/2` warns on `mix.lock`'s quoted keywords; `MixFile` passes `emit_warnings: false`.
- The formatter parenthesises `rule`/`assert_pass`/`assert_fail` unless `.formatter.exs` lists them in `locals_without_parens`, and does not remove parens it already added.
- `setup_all` does not get a `tmp_dir`; use `Fixtures.repo/1`.
- Concuerror from hex (0.21.0) predates OTP 28 (`erlang:list_to_integer` and `monitor/3` are unsupported); the dependency is the GitHub master. It still rejects `erlang:monitor/3`, which `Task.async` uses, so the runner must not use `Task`. Intentional kills need `treat_as_normal: [:killed]`.
- Property generators: `uniq_list_of` over a small pool raises `TooManyDuplicatesError` regardless of `max_length`; use a boolean mask. Git's xdiff is not a minimal edit script even with `--minimal`, so only line deltas and length bounds can be compared with `git diff --numstat`.
- In zsh a word starting with `=` is a command lookup (`echo =====` fails); avoid it in shell snippets.
- Never `git reset --hard` with uncommitted work in the tree; a refused hook means the commit did not happen, so `HEAD~1` is the previous real commit. Stash or commit first.
- Dialyzer rejects `MapSet.t()` inside a map type in a `@spec` (opaque subterm); `RuleSet.env()` uses plain lists.
- Map key order is not stable across OTP versions; `Presubmit.JSON` sorts keys.
- macOS temp dirs are symlinks (`/var` → `/private/var`); compare paths by suffix in tests, and let git compute relative paths (`--show-prefix`).
- Rules that only make sense on a commit declare `sources: [:head, :rev]`; in a hook the change set is `:staged`.
- `git commit --amend -m …` reaches `prepare-commit-msg` with source `message`, not `commit`: undetectable as an amend. Editor/`--no-edit` amends are detected.
- A commit can exempt itself with `Presubmit-Skip:`/`No-Presubmit:` trailers; prefer that to `--no-verify` so the decision is in history.

## CI

`.github/workflows/ci.yml` has a `commits` job with `fetch-depth: 0`: pull requests run `mix presubmit --range base..head` (HEAD on a PR is a synthetic merge commit, which the tool refuses), pushes run `--range before..sha` (`--head` when `before` is the all-zeros SHA of a new branch).

## Commit message style

```
[component] brief description

Optional longer explanation.
```

## Changelog

Every user-visible change must have an entry in `CHANGELOG.md` under an `## Unreleased` section at the top.
