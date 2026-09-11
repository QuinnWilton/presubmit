defmodule AssertCommit.Scenarios.PhoenixTest do
  @moduledoc """
  The Phoenix, Ecto, OTP, ExUnit, and Hygiene rule sets run against
  `fixtures/phoenix`: one scenario branch per patch, each named for the
  situation it reproduces. Nothing here names a module or a path.
  """

  use ExUnit.Case, async: true

  import AssertCommit.Query
  import AssertCommit.RuleHelpers

  alias AssertCommit.Assertions.{Ecto, Phoenix}
  alias AssertCommit.{Fixtures, Rules}

  setup_all do: %{repo: Fixtures.repo("phoenix")}

  describe "Rules.Phoenix :routed" do
    test "passes when a router routes the new controller", %{repo: repo} do
      commit = scenario(repo, :routed_controller)
      assert [route] = Phoenix.routes_added(commit)
      assert route.plug in modules_added(commit)
      assert_pass(run_rule(Rules.Phoenix, :routed, commit))
    end

    test "passes for a `live` route", %{repo: repo} do
      commit = scenario(repo, :routed_live_view)
      assert [%{kind: :live}] = Phoenix.routes_added(commit)
      assert_pass(run_rule(Rules.Phoenix, :routed, commit))
    end

    test "fails when no router was touched", %{repo: repo} do
      assert_fail(run_rule(Rules.Phoenix, :routed, scenario(repo, :unrouted_controller)), message)
      assert message =~ "were added but no router routes to them"
      assert message =~ "(controller)"
    end

    test "fails for an unrouted LiveView", %{repo: repo} do
      assert_fail(run_rule(Rules.Phoenix, :routed, scenario(repo, :unrouted_live_view)), message)
      assert message =~ "(live_view)"
    end

    test "fails when the router was edited but does not route the controller", %{repo: repo} do
      commit = scenario(repo, :router_touched_not_wired)
      assert modified(commit, ~r/router\.ex$/) != []
      assert Phoenix.routes_added(commit) == []
      assert_fail(run_rule(Rules.Phoenix, :routed, commit), message)
      assert message =~ "no router routes to them"
    end

    test "is vacuous when nothing routable was added", %{repo: repo} do
      commit = scenario(repo, :migration_newest)
      assert modules_added(commit) != []
      assert_pass(run_rule(Rules.Phoenix, :routed, commit))
    end
  end

  describe "Rules.Ecto :migrations_ordered" do
    test "passes for a migration newer than every existing one", %{repo: repo} do
      commit = scenario(repo, :migration_newest)
      assert [added] = Ecto.migrations_added(commit)
      assert added == List.last(Ecto.migrations(commit))
      assert_pass(run_rule(Rules.Ecto, :migrations_ordered, commit))
    end

    test "fails for a migration rebased underneath a newer one", %{repo: repo} do
      commit = scenario(repo, :migration_rebased)
      [added] = Ecto.migrations_added(commit)
      assert_fail(run_rule(Rules.Ecto, :migrations_ordered, commit), message)
      assert message =~ "older than the newest existing migration"
      assert message =~ "#{added.path} (#{added.version})"
      assert message =~ "Regenerate them"
    end

    test "is vacuous when no migration was added", %{repo: repo} do
      commit = scenario(repo, :routed_controller)
      assert Ecto.migrations_added(commit) == []
      assert_pass(run_rule(Rules.Ecto, :migrations_ordered, commit))
    end
  end

  describe "Rules.Ecto :migrations_immutable" do
    test "passes when only new migrations are added", %{repo: repo} do
      assert_pass(run_rule(Rules.Ecto, :migrations_immutable, scenario(repo, :migration_newest)))
    end

    test "fails when an existing migration is edited", %{repo: repo} do
      commit = scenario(repo, :migration_edited)
      [path] = modified(commit)
      assert_fail(run_rule(Rules.Ecto, :migrations_immutable, commit), message)
      assert message =~ "#{path} (modified)"
    end
  end

  describe "Rules.Ecto :schema_changes_migrated" do
    test "passes when the added column is added by an added migration", %{repo: repo} do
      assert_pass(
        run_rule(
          Rules.Ecto,
          :schema_changes_migrated,
          scenario(repo, :schema_field_with_migration)
        )
      )
    end

    test "fails naming the column and table", %{repo: repo} do
      assert_fail(
        run_rule(
          Rules.Ecto,
          :schema_changes_migrated,
          scenario(repo, :schema_field_without_migration)
        ),
        message
      )

      assert message =~ "were added without a migration adding them to the table"
      assert message =~ ~r/\.name \(table "users"\)/
      assert message =~ "No migration was added in this commit."
    end

    test "is vacuous when no schema changed", %{repo: repo} do
      assert_pass(
        run_rule(Rules.Ecto, :schema_changes_migrated, scenario(repo, :migration_newest))
      )
    end
  end

  describe "Rules.Ecto :indexes_concurrent" do
    test "passes for a concurrent index in a non-transactional migration", %{repo: repo} do
      assert_pass(
        run_rule(Rules.Ecto, :indexes_concurrent, scenario(repo, :safe_index_migration))
      )
    end

    test "fails naming both problems", %{repo: repo} do
      assert_fail(
        run_rule(Rules.Ecto, :indexes_concurrent, scenario(repo, :unsafe_index_migration)),
        message
      )

      assert message =~ "is missing `concurrently: true`"
      assert message =~ "needs `@disable_ddl_transaction true`"
    end
  end

  describe "Rules.Ecto :migrations_reversible" do
    test "passes for a `change/0` migration without raw SQL", %{repo: repo} do
      assert_pass(run_rule(Rules.Ecto, :migrations_reversible, scenario(repo, :migration_newest)))
    end
  end

  describe "Rules.OTP :supervised" do
    test "passes when the application starts the new server", %{repo: repo} do
      assert_pass(run_rule(Rules.OTP, :supervised, scenario(repo, :supervised_genserver)))
    end

    test "fails when nothing starts it", %{repo: repo} do
      commit = scenario(repo, :unsupervised_genserver)
      [orphan] = modules_added(commit)
      assert_fail(run_rule(Rules.OTP, :supervised, commit), message)
      assert message =~ "#{inspect(orphan)} (gen_server)"
      assert message =~ "Supervision trees checked:"
    end
  end

  describe "Rules.ExUnit :tested" do
    test "passes when a <Module>Test exists", %{repo: repo} do
      assert_pass(run_rule(Rules.ExUnit, :tested, scenario(repo, :routed_controller)))
    end

    test "fails naming the untested module", %{repo: repo} do
      commit = scenario(repo, :unsupervised_genserver)
      [untested] = modules_added(commit)
      assert_fail(run_rule(Rules.ExUnit, :tested, commit), message)
      assert message =~ "have no test module"
      assert message =~ inspect(untested)
    end
  end

  describe "Rules.Hygiene :no_debug_calls" do
    test "passes on clean commits", %{repo: repo} do
      assert_pass(run_rule(Rules.Hygiene, :no_debug_calls, scenario(repo, :routed_controller)))
    end

    test "fails pointing at the line", %{repo: repo} do
      assert_fail(
        run_rule(Rules.Hygiene, :no_debug_calls, scenario(repo, :debug_left_in)),
        message
      )

      assert message =~ ~r/^  lib\/.*:\d+: IO\.inspect\(/m
    end
  end
end
