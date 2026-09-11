defmodule AssertCommit.Assertions do
  @moduledoc """
  ExUnit assertion verbs over a `AssertCommit.Commit`.

  Every verb takes the commit first and fails with a message that names the
  offending paths, modules, or lines and says what would satisfy it. Path
  arguments accept any `AssertCommit.Pattern`: a `Regex`, an exact path
  string, or a list of either.

  ## Files

  - `assert_added/2`, `refute_added/2`, `assert_modified/2`, `refute_modified/2`,
    `assert_removed/2`, `refute_removed/2`, `assert_touched/2`, `refute_touched/2`
  - `assert_immutable/2` — files matching the pattern are never edited, deleted, or renamed away
  - `assert_coupled/3` — if anything matching the trigger changed, something matching `then:` did too
  - `assert_counterpart/3` — each added file has a sibling derived from its path
  - `assert_exists/2`, `refute_exists/2` — after-tree existence
  - `assert_last_by_name/3` — an added file sorts last among its peers

  ## Lines

  - `refute_added_lines/3` — no added line matches a regex (debug calls, secrets, merge markers)

  ## Elixir source

  - `assert_references/3` — a file's AST names a module, aliases resolved
  - `assert_specs/2` — every newly added public function has a `@spec`
  - `assert_moduledoc/2` — every newly added module has a `@moduledoc`
  - `assert_removals_deprecated/1` — removed public functions were `@deprecated` first
  - `assert_pure_move/1` — a commit containing renames contains nothing else

  Library-aware verbs live in `AssertCommit.Assertions.Phoenix`, `.Ecto`,
  `.OTP`, `.ExUnit`, `.Mix`, and `.Changelog`; `use AssertCommit` imports
  them all.

  ## Message

  - `assert_subject/2`, `refute_subject/2`, `assert_message/2`
  - `assert_trailer/2`, `assert_trailer/3`, `refute_trailer/2`
  - `assert_scope_matches_paths/3` — the subject's scope agrees with the paths touched

  ## Shape

  - `assert_max_files/2`, `assert_max_additions/2`
  """

  import AssertCommit.Assertions.Flunk, only: [flunk: 1, indent: 1]

  alias AssertCommit.{Commit, FileChange, Pattern, Query}
  alias AssertCommit.Source.Facts
  alias AssertCommit.Source.Facts.Function

  @type pattern :: Pattern.t()

  ## Files

  @doc "Asserts at least one file matching `pattern` was added."
  @spec assert_added(Commit.t(), pattern()) :: :ok
  def assert_added(%Commit{} = commit, pattern) do
    case Query.added(commit, pattern) do
      [] ->
        flunk("Expected a file matching #{Pattern.format(pattern)} to be added, but none was.")

      _ ->
        :ok
    end
  end

  @doc "Asserts no file matching `pattern` was added."
  @spec refute_added(Commit.t(), pattern()) :: :ok
  def refute_added(%Commit{} = commit, pattern) do
    case Query.added(commit, pattern) do
      [] ->
        :ok

      paths ->
        flunk([
          "Expected no file matching #{Pattern.format(pattern)} to be added, but these were:"
          | indent(paths)
        ])
    end
  end

  @doc "Asserts at least one file matching `pattern` was modified in place."
  @spec assert_modified(Commit.t(), pattern()) :: :ok
  def assert_modified(%Commit{} = commit, pattern) do
    case Query.modified(commit, pattern) do
      [] ->
        flunk("Expected a file matching #{Pattern.format(pattern)} to be modified, but none was.")

      _ ->
        :ok
    end
  end

  @doc "Asserts no file matching `pattern` was modified."
  @spec refute_modified(Commit.t(), pattern()) :: :ok
  def refute_modified(%Commit{} = commit, pattern) do
    case Query.modified(commit, pattern) do
      [] ->
        :ok

      paths ->
        flunk([
          "Expected no file matching #{Pattern.format(pattern)} to be modified, but these were:"
          | indent(paths)
        ])
    end
  end

  @doc "Asserts at least one file matching `pattern` was removed."
  @spec assert_removed(Commit.t(), pattern()) :: :ok
  def assert_removed(%Commit{} = commit, pattern) do
    case Query.removed(commit, pattern) do
      [] ->
        flunk("Expected a file matching #{Pattern.format(pattern)} to be removed, but none was.")

      _ ->
        :ok
    end
  end

  @doc "Asserts no file matching `pattern` was removed."
  @spec refute_removed(Commit.t(), pattern()) :: :ok
  def refute_removed(%Commit{} = commit, pattern) do
    case Query.removed(commit, pattern) do
      [] ->
        :ok

      paths ->
        flunk([
          "Expected no file matching #{Pattern.format(pattern)} to be removed, but these were:"
          | indent(paths)
        ])
    end
  end

  @doc "Asserts the commit touches at least one path matching `pattern`."
  @spec assert_touched(Commit.t(), pattern()) :: :ok
  def assert_touched(%Commit{} = commit, pattern) do
    if Query.touches?(commit, pattern) do
      :ok
    else
      flunk([
        "Expected the commit to touch a path matching #{Pattern.format(pattern)}, but it touches only:"
        | indent(Query.touched(commit))
      ])
    end
  end

  @doc "Asserts the commit touches no path matching `pattern`."
  @spec refute_touched(Commit.t(), pattern()) :: :ok
  def refute_touched(%Commit{} = commit, pattern) do
    case Query.touched(commit, pattern) do
      [] ->
        :ok

      paths ->
        flunk([
          "Expected the commit not to touch #{Pattern.format(pattern)}, but it touches:"
          | indent(paths)
        ])
    end
  end

  @doc """
  Asserts that files matching `pattern` which existed before the commit are
  unchanged: not modified, deleted, or renamed away. Additions are fine.
  """
  @spec assert_immutable(Commit.t(), pattern()) :: :ok
  def assert_immutable(%Commit{changes: changes}, pattern) do
    violations =
      for change <- changes,
          change.status != :added,
          before_path = FileChange.before_path(change),
          Pattern.matches?(before_path, pattern),
          do: "#{before_path} (#{change.status})"

    case violations do
      [] ->
        :ok

      _ ->
        flunk([
          "Files matching #{Pattern.format(pattern)} are immutable once committed, but this commit changes:"
          | indent(violations)
        ])
    end
  end

  @doc """
  Asserts that if any path matching `trigger` was touched, at least one path
  matching `opts[:then]` was touched too.

  This is the "if you changed X you must also change Y" rule on paths alone.
  Prefer an after-tree invariant when one exists — a coupling on the diff
  passes when Y was touched for an unrelated reason.

  ## Examples

      assert_coupled(commit, "mix.exs", then: "mix.lock")
  """
  @spec assert_coupled(Commit.t(), pattern(), then: pattern()) :: :ok
  def assert_coupled(%Commit{} = commit, trigger, then: expected) do
    triggered = Query.touched(commit, trigger)

    cond do
      triggered == [] ->
        :ok

      Query.touches?(commit, expected) ->
        :ok

      true ->
        flunk([
          "The commit touches #{Pattern.format(trigger)}:",
          indent(triggered),
          "",
          "so it must also touch #{Pattern.format(expected)}, but nothing matching that changed."
        ])
    end
  end

  @doc """
  Asserts that every added file matching `regex` has a counterpart in the
  after tree, named by substituting the captures into `template`.

  ## Examples

      assert_counterpart(commit, ~r{^lib/(.+)\\.ex$}, "test/\\\\1_test.exs")
  """
  @spec assert_counterpart(Commit.t(), Regex.t(), String.t()) :: :ok
  def assert_counterpart(%Commit{} = commit, %Regex{} = regex, template)
      when is_binary(template) do
    missing =
      for path <- Query.added(commit, regex),
          counterpart = Regex.replace(regex, path, template),
          not Query.exists?(commit, counterpart),
          do: "#{path} → expected #{counterpart}"

    case missing do
      [] ->
        :ok

      _ ->
        flunk(["These added files have no counterpart in the resulting tree:" | indent(missing)])
    end
  end

  @doc "Asserts `path` exists after the commit."
  @spec assert_exists(Commit.t(), String.t()) :: :ok
  def assert_exists(%Commit{} = commit, path) do
    if Query.exists?(commit, path),
      do: :ok,
      else: flunk("Expected #{path} to exist after the commit, but it does not.")
  end

  @doc "Asserts `path` does not exist after the commit."
  @spec refute_exists(Commit.t(), String.t()) :: :ok
  def refute_exists(%Commit{} = commit, path) do
    if Query.exists?(commit, path),
      do: flunk("Expected #{path} not to exist after the commit, but it does."),
      else: :ok
  end

  @doc """
  Asserts that `path` sorts last (byte-wise) among every after-tree path
  matching `opts[:among]`.

  For Ecto migrations prefer `AssertCommit.Assertions.Ecto.assert_migrations_ordered/1`,
  which finds migrations by their `use` rather than by path.
  """
  @spec assert_last_by_name(Commit.t(), String.t(), among: pattern()) :: :ok
  def assert_last_by_name(%Commit{} = commit, path, among: pattern) do
    peers = Query.after_paths(commit, pattern)

    cond do
      path not in peers ->
        flunk(
          "#{path} is not in the resulting tree (or does not match #{Pattern.format(pattern)})."
        )

      List.last(peers) == path ->
        :ok

      true ->
        later = peers |> Enum.drop_while(&(&1 != path)) |> tl()

        flunk([
          "Expected #{path} to sort last among #{Pattern.format(pattern)}, but these sort after it:"
          | indent(later)
        ])
    end
  end

  ## Lines

  @doc """
  Asserts no line added by the commit matches `regex`.

  Restrict the files considered with `in: pattern`. Failures list each
  offending `path:line` with the line's text.

  ## Examples

      refute_added_lines(commit, ~r/IO\\.inspect|dbg\\(/, in: ~r{^lib/})
  """
  @spec refute_added_lines(Commit.t(), Regex.t(), keyword()) :: :ok
  def refute_added_lines(%Commit{} = commit, %Regex{} = regex, opts \\ []) do
    hits =
      for {path, no, text} <- Query.added_lines(commit, Keyword.get(opts, :in)),
          Regex.match?(regex, text),
          do: "#{path}:#{no}: #{String.trim(text)}"

    case hits do
      [] -> :ok
      _ -> flunk(["Added lines match #{inspect(regex)}:" | indent(hits)])
    end
  end

  ## Elixir source

  @doc """
  Asserts that the after-tree file at `path` references `module` by name.

  References are resolved through the file's aliases, so `alias Demo.Accounts`
  followed by `Accounts.User` counts as a reference to `Demo.Accounts.User`.
  For Phoenix routers use `AssertCommit.Assertions.Phoenix.assert_routed/1`,
  which understands `scope` aliasing.
  """
  @spec assert_references(Commit.t(), String.t(), module()) :: :ok
  def assert_references(%Commit{after: tree}, path, module) when is_atom(module) do
    case Facts.extract(tree, path) do
      {:error, :enoent} ->
        flunk(
          "Expected #{path} to reference #{inspect(module)}, but #{path} does not exist after the commit."
        )

      {:error, reason} ->
        flunk(
          "Expected #{path} to reference #{inspect(module)}, but #{path} does not parse: #{inspect(reason)}"
        )

      {:ok, %Facts{modules: modules}} ->
        if Enum.any?(modules, &(module in &1.references)),
          do: :ok,
          else:
            flunk(
              "Expected #{path} to reference #{inspect(module)}, but it does not mention that module anywhere."
            )
    end
  end

  @doc """
  Asserts every public function the commit adds in files matching `pattern`
  (default: `lib/`) has a `@spec`.

  Macros and `@impl` callbacks are exempt: callbacks take their contract from
  the behaviour, and macros are not conventionally spec'd. A spec for a
  head's full arity covers every arity its default arguments generate.
  """
  @spec assert_specs(Commit.t(), pattern()) :: :ok
  def assert_specs(%Commit{} = commit, pattern \\ ~r{^lib/}) do
    missing =
      for %Function{kind: :def, impl?: false} = f <- Query.functions_added(commit, pattern),
          not f.spec?,
          do: format_function(f)

    case missing do
      [] -> :ok
      _ -> flunk(["These newly added public functions have no @spec:" | indent(missing)])
    end
  end

  @doc """
  Asserts every module the commit adds in files matching `pattern`
  (default: `lib/`) declares a `@moduledoc` (`@moduledoc false` counts as a
  deliberate choice).
  """
  @spec assert_moduledoc(Commit.t(), pattern()) :: :ok
  def assert_moduledoc(%Commit{} = commit, pattern \\ ~r{^lib/}) do
    missing =
      for m <- Query.module_facts_added(commit, pattern), is_nil(m.moduledoc), do: inspect(m.name)

    case missing do
      [] -> :ok
      _ -> flunk(["These newly added modules have no @moduledoc:" | indent(missing)])
    end
  end

  @doc """
  Asserts every API function the commit removes was marked `@deprecated`
  before the commit, so consumers had a release to migrate. Functions marked
  `@doc false` are not API and may be removed freely.
  """
  @spec assert_removals_deprecated(Commit.t()) :: :ok
  def assert_removals_deprecated(%Commit{} = commit) do
    undeprecated =
      for %Function{} = f <- Query.functions_removed(commit),
          Function.api?(f),
          not f.deprecated?,
          do: format_function(f)

    case undeprecated do
      [] ->
        :ok

      _ ->
        flunk([
          "These public functions were removed without a prior @deprecated:"
          | indent(undeprecated)
        ])
    end
  end

  @doc """
  Asserts that a commit containing renames is a pure move: every file change
  is a rename, every module change is a rename, and no function was added,
  removed, or had its body changed.

  Commits with no renames pass trivially, so this can be applied to every
  commit to enforce "moves are their own commit".
  """
  @spec assert_pure_move(Commit.t()) :: :ok
  def assert_pure_move(%Commit{changes: changes} = commit) do
    if Enum.any?(changes, &(&1.status == :renamed)) do
      diff = Query.elixir_diff(commit)

      problems =
        for(c <- changes, c.status != :renamed, do: "#{c.path} (#{c.status})") ++
          Enum.map(diff.modules.added, &"#{inspect(&1.name)} (module added)") ++
          Enum.map(diff.modules.removed, &"#{inspect(&1.name)} (module removed)") ++
          Enum.map(diff.functions.added, &"#{format_function(&1)} (added)") ++
          Enum.map(diff.functions.removed, &"#{format_function(&1)} (removed)") ++
          Enum.map(diff.functions.body_changed, fn {_, f} ->
            "#{format_function(f)} (body changed, line #{f.line})"
          end)

      case problems do
        [] ->
          :ok

        _ ->
          flunk(
            ["This commit renames files, so it must contain nothing else. It also has:"] ++
              indent(problems) ++
              ["", "Land the move on its own and edit the moved code in a separate commit."]
          )
      end
    else
      :ok
    end
  end

  defp format_function(%Function{module: m, name: f, arity: a}), do: "#{inspect(m)}.#{f}/#{a}"

  ## Message

  @doc "Asserts the subject line matches `regex`."
  @spec assert_subject(Commit.t(), Regex.t()) :: :ok
  def assert_subject(%Commit{} = commit, %Regex{} = regex) do
    subject = Query.subject(commit)

    if Regex.match?(regex, subject),
      do: :ok,
      else: flunk("Expected the subject to match #{inspect(regex)}, but it is:\n\n  #{subject}")
  end

  @doc "Asserts the subject line does not match `regex`."
  @spec refute_subject(Commit.t(), Regex.t()) :: :ok
  def refute_subject(%Commit{} = commit, %Regex{} = regex) do
    subject = Query.subject(commit)

    if Regex.match?(regex, subject),
      do:
        flunk("Expected the subject not to match #{inspect(regex)}, but it is:\n\n  #{subject}"),
      else: :ok
  end

  @doc "Asserts the full raw message matches `regex`."
  @spec assert_message(Commit.t(), Regex.t()) :: :ok
  def assert_message(%Commit{} = commit, %Regex{} = regex) do
    raw = Query.message!(commit).raw

    if Regex.match?(regex, raw),
      do: :ok,
      else:
        flunk(
          "Expected the message to match #{inspect(regex)}, but it is:\n\n#{indent_text(raw)}"
        )
  end

  @doc """
  Asserts the message carries at least one `key` trailer; with `regex`,
  that at least one of its values matches.
  """
  @spec assert_trailer(Commit.t(), String.t(), Regex.t() | nil) :: :ok
  def assert_trailer(%Commit{} = commit, key, regex \\ nil) do
    values = Query.trailer(commit, key)

    cond do
      values == [] ->
        flunk([
          "Expected a `#{key}:` trailer, but the message has #{describe_trailers(Query.trailers(commit))}.",
          "",
          "Trailers are `Key: value` lines in the final paragraph of the message."
        ])

      is_nil(regex) or Enum.any?(values, &Regex.match?(regex, &1)) ->
        :ok

      true ->
        flunk([
          "Expected a `#{key}:` trailer matching #{inspect(regex)}, but the values are:"
          | indent(values)
        ])
    end
  end

  @doc "Asserts the message carries no `key` trailer."
  @spec refute_trailer(Commit.t(), String.t()) :: :ok
  def refute_trailer(%Commit{} = commit, key) do
    case Query.trailer(commit, key) do
      [] -> :ok
      values -> flunk(["Expected no `#{key}:` trailer, but found:" | indent(values)])
    end
  end

  @doc """
  Asserts the subject names a scope that agrees with the paths touched.

  `regex` must capture the scope from the subject; `path_pattern` is a
  function from the captured scope to a pattern every touched path must
  match.

  ## Examples

      assert_scope_matches_paths(commit, ~r/^\\[(\\w+)\\]/, fn scope -> ~r{^\#{scope}/} end)
  """
  @spec assert_scope_matches_paths(Commit.t(), Regex.t(), (String.t() -> pattern())) :: :ok
  def assert_scope_matches_paths(%Commit{} = commit, %Regex{} = regex, path_pattern)
      when is_function(path_pattern, 1) do
    subject = Query.subject(commit)

    case Regex.run(regex, subject, capture: :all_but_first) do
      [scope | _] ->
        pattern = path_pattern.(scope)

        case Enum.reject(Query.touched(commit), &Pattern.matches?(&1, pattern)) do
          [] ->
            :ok

          outside ->
            flunk([
              "The subject scopes this commit to #{inspect(scope)} (#{Pattern.format(pattern)}), but it also touches:"
              | indent(outside)
            ])
        end

      _ ->
        flunk(
          "Expected the subject to declare a scope matching #{inspect(regex)}, but it is:\n\n  #{subject}"
        )
    end
  end

  ## Shape

  @doc "Asserts the commit changes at most `max` files."
  @spec assert_max_files(Commit.t(), non_neg_integer()) :: :ok
  def assert_max_files(%Commit{changes: changes}, max) when is_integer(max) do
    count = length(changes)

    if count <= max,
      do: :ok,
      else:
        flunk(
          "Expected at most #{max} changed files, but the commit changes #{count}. Split it into smaller commits."
        )
  end

  @doc "Asserts the commit adds at most `max` lines."
  @spec assert_max_additions(Commit.t(), non_neg_integer()) :: :ok
  def assert_max_additions(%Commit{} = commit, max) when is_integer(max) do
    count = Query.additions(commit)

    if count <= max,
      do: :ok,
      else:
        flunk(
          "Expected at most #{max} added lines, but the commit adds #{count}. Split it into smaller commits."
        )
  end

  defp indent_text(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  defp describe_trailers([]), do: "no trailers"

  defp describe_trailers(trailers),
    do: "only: " <> Enum.map_join(trailers, ", ", fn {k, _} -> k end)
end
