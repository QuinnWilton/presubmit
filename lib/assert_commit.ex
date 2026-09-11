defmodule AssertCommit do
  @moduledoc """
  ExUnit assertions over the shape and contents of git commits.

  `use AssertCommit` loads the change set once per test module and injects
  it into the test context as `commit`, alongside the assertion verbs from
  `AssertCommit.Assertions` and the query helpers from `AssertCommit.Query`.

      defmodule MyApp.CommitTest do
        use ExUnit.Case, async: true
        use AssertCommit

        test "new migrations sort last", %{commit: commit} do
          for path <- added(commit, ~r{^priv/repo/migrations/}) do
            assert_last_by_name(commit, path, among: ~r{^priv/repo/migrations/})
          end
        end

        test "new controllers are routed", %{commit: commit} do
          for mod <- modules_added(commit, ~r/_controller\\.ex$/) do
            assert_references(commit, "lib/my_app_web/router.ex", mod)
          end
        end
      end

  ## Options

  - `:repo` — repository path (default: the current directory).
  - `:rev` — revision to load (default: `"HEAD"`).
  - `:source` — `:rev` (default) or `:staged` to assert on the index instead
    of a commit.

  Any option may be a function of the test context, evaluated per test:

      use AssertCommit, repo: & &1.repo, rev: &"scenario/\#{&1.scenario}"

      @tag scenario: :unrouted_controller
      test "unrouted controllers fail", %{commit: commit} do
        assert_raise ExUnit.AssertionError, fn -> assert_routed(commit) end
      end

  Tests get the `:assert_commit` module tag, so `mix test --exclude assert_commit`
  skips them in a checkout with no meaningful `HEAD`. (The tag is not `:commit`
  because tags are merged into the context after `setup_all`, and would clobber
  the `commit` key.)

  ## In CI

  A depth-1 checkout has no parent for `HEAD`. With `actions/checkout`, set
  `fetch-depth: 2`. On `pull_request` events `HEAD` is a synthetic merge
  commit; assert on `github.event.pull_request.head.sha` or on each commit
  in `base.sha..head.sha` instead.
  """

  alias AssertCommit.Commit

  @doc false
  defmacro __using__(opts) do
    dynamic? = Enum.any?(opts, fn {_k, v} -> match?({:fn, _, _}, v) or match?({:&, _, _}, v) end)

    setup =
      if dynamic? do
        quote do
          setup context do
            %{commit: AssertCommit.commit(unquote(opts), context)}
          end
        end
      else
        quote do
          setup_all do
            %{commit: AssertCommit.commit(unquote(opts))}
          end
        end
      end

    quote do
      import AssertCommit.Assertions
      import AssertCommit.Assertions.Changelog
      import AssertCommit.Assertions.Ecto
      import AssertCommit.Assertions.ExUnit
      import AssertCommit.Assertions.Mix
      import AssertCommit.Assertions.OTP
      import AssertCommit.Assertions.Phoenix
      import AssertCommit.Query

      @moduletag :assert_commit

      unquote(setup)
    end
  end

  @doc """
  Loads a change set according to `opts` (see `use AssertCommit`).

  Option values may be one-argument functions of the test `context`, in
  which case they are resolved per test; `use AssertCommit` then loads the
  commit in `setup` rather than `setup_all`.
  """
  @spec commit(keyword(), map()) :: Commit.t()
  def commit(opts \\ [], context \\ %{}) do
    opts = Enum.map(opts, fn {k, v} -> {k, if(is_function(v, 1), do: v.(context), else: v)} end)

    case Keyword.get(opts, :source, :rev) do
      :staged -> Commit.staged(opts)
      :rev -> Commit.rev(Keyword.get(opts, :rev, "HEAD"), opts)
    end
  end
end
