defmodule AssertCommit.Scenarios.PhoenixTest do
  @moduledoc """
  Process rules for a Phoenix + Ecto application, run against
  `fixtures/phoenix`: one scenario branch per patch, each named for the
  situation it reproduces. Every test is the rule exactly as a team would
  write it; nothing here names a module or a path.
  """

  use ExUnit.Case, async: true
  use AssertCommit, repo: & &1.repo, rev: &"scenario/#{&1.scenario}"

  setup_all do: %{repo: AssertCommit.Fixtures.repo("phoenix")}

  describe "assert_routed/1: added controllers and LiveViews are reachable" do
    @tag scenario: :routed_controller
    test "passes when a router routes the new controller", %{commit: commit} do
      assert [route] = routes_added(commit)
      assert route.plug in modules_added(commit)
      assert_routed(commit)
    end

    @tag scenario: :routed_live_view
    test "passes for a `live` route", %{commit: commit} do
      assert [%{kind: :live}] = routes_added(commit)
      assert_routed(commit)
    end

    @tag scenario: :unrouted_controller
    test "fails when no router was touched", %{commit: commit} do
      error = assert_raise ExUnit.AssertionError, fn -> assert_routed(commit) end
      assert error.message =~ "were added but no router routes to them"
      assert error.message =~ "(controller)"
    end

    @tag scenario: :unrouted_live_view
    test "fails for an unrouted LiveView", %{commit: commit} do
      error = assert_raise ExUnit.AssertionError, fn -> assert_routed(commit) end
      assert error.message =~ "(live_view)"
    end

    @tag scenario: :router_touched_not_wired
    test "fails when the router was edited but does not route the controller", %{commit: commit} do
      # The router file changed, so a path-coupling rule is satisfied. The route is still missing.
      assert_coupled(commit, ~r/_controller\.ex$/, then: ~r/router\.ex$/)
      assert routes_added(commit) == []

      error = assert_raise ExUnit.AssertionError, fn -> assert_routed(commit) end
      assert error.message =~ "no router routes to them"
    end

    @tag scenario: :migration_newest
    test "is vacuous when nothing routable was added", %{commit: commit} do
      assert modules_added(commit) != []
      assert_routed(commit)
    end
  end

  describe "assert_migrations_ordered/1" do
    @tag scenario: :migration_newest
    test "passes for a migration newer than every existing one", %{commit: commit} do
      assert [added] = migrations_added(commit)
      assert added == List.last(migrations(commit))
      assert_migrations_ordered(commit)
    end

    @tag scenario: :migration_rebased
    test "fails for a migration rebased underneath a newer one", %{commit: commit} do
      [added] = migrations_added(commit)

      error = assert_raise ExUnit.AssertionError, fn -> assert_migrations_ordered(commit) end
      assert error.message =~ "older than the newest existing migration"
      assert error.message =~ "#{added.path} (#{added.version})"
      assert error.message =~ "Regenerate them"
    end

    @tag scenario: :routed_controller
    test "is vacuous when no migration was added", %{commit: commit} do
      assert migrations_added(commit) == []
      assert_migrations_ordered(commit)
    end
  end

  describe "assert_migrations_immutable/1" do
    @tag scenario: :migration_newest
    test "passes when only new migrations are added", %{commit: commit} do
      assert_migrations_immutable(commit)
    end

    @tag scenario: :migration_edited
    test "fails when an existing migration is edited", %{commit: commit} do
      [path] = modified(commit)

      error = assert_raise ExUnit.AssertionError, fn -> assert_migrations_immutable(commit) end
      assert error.message =~ "#{path} (modified)"
    end
  end

  describe "assert_schema_changes_migrated/1" do
    @tag scenario: :schema_field_with_migration
    test "passes when the added column is added by an added migration", %{commit: commit} do
      assert_schema_changes_migrated(commit)
    end

    @tag scenario: :schema_field_without_migration
    test "fails naming the column and table", %{commit: commit} do
      error = assert_raise ExUnit.AssertionError, fn -> assert_schema_changes_migrated(commit) end
      assert error.message =~ "were added without a migration adding them to the table"
      assert error.message =~ ~r/\.name \(table "users"\)/
      assert error.message =~ "No migration was added in this commit."
    end

    @tag scenario: :migration_newest
    test "is vacuous when no schema changed", %{commit: commit} do
      assert_schema_changes_migrated(commit)
    end
  end

  describe "assert_indexes_concurrent/1" do
    @tag scenario: :safe_index_migration
    test "passes for a concurrent index in a non-transactional migration", %{commit: commit} do
      assert_indexes_concurrent(commit)
    end

    @tag scenario: :unsafe_index_migration
    test "fails naming both problems", %{commit: commit} do
      error = assert_raise ExUnit.AssertionError, fn -> assert_indexes_concurrent(commit) end
      assert error.message =~ "is missing `concurrently: true`"
      assert error.message =~ "needs `@disable_ddl_transaction true`"
    end
  end

  describe "assert_migrations_reversible/1" do
    @tag scenario: :migration_newest
    test "passes for a `change/0` migration without raw SQL", %{commit: commit} do
      assert_migrations_reversible(commit)
    end
  end

  describe "assert_supervised/1" do
    @tag scenario: :supervised_genserver
    test "passes when the application starts the new server", %{commit: commit} do
      assert_supervised(commit)
    end

    @tag scenario: :unsupervised_genserver
    test "fails when nothing starts it", %{commit: commit} do
      [orphan] = modules_added(commit)

      error = assert_raise ExUnit.AssertionError, fn -> assert_supervised(commit) end
      assert error.message =~ "#{inspect(orphan)} (gen_server)"
      assert error.message =~ "Supervision trees checked:"
    end
  end

  describe "assert_tested/1" do
    @tag scenario: :routed_controller
    test "passes when a <Module>Test exists", %{commit: commit} do
      assert_tested(commit)
    end

    @tag scenario: :unsupervised_genserver
    test "fails naming the untested module", %{commit: commit} do
      [untested] = modules_added(commit)

      error = assert_raise ExUnit.AssertionError, fn -> assert_tested(commit) end
      assert error.message =~ "have no test module"
      assert error.message =~ inspect(untested)
    end
  end

  describe "refute_added_lines/3: no debugging calls" do
    @debug ~r/\b(IO\.inspect|dbg|IEx\.pry)\(/

    @tag scenario: :routed_controller
    test "passes on clean commits", %{commit: commit} do
      refute_added_lines(commit, @debug, in: ~r{^lib/})
    end

    @tag scenario: :debug_left_in
    test "fails pointing at the line", %{commit: commit} do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          refute_added_lines(commit, @debug, in: ~r{^lib/})
        end

      assert error.message =~ ~r/^  lib\/.*:\d+: IO\.inspect\(/m
    end
  end
end
