defmodule AssertCommit.UmbrellaTest do
  @moduledoc "Every default that names a directory must work under apps/<name>/ too."
  use ExUnit.Case, async: true

  import AssertCommit.Assertions
  import AssertCommit.Assertions.ExUnit
  import AssertCommit.Assertions.Mix
  import AssertCommit.Query

  alias AssertCommit.{Commit, Config, MixFile, Rules, Tree}

  @app "apps/shop/lib/shop/cart.ex"
  @test "apps/shop/test/shop/cart_test.exs"

  test "specs, moduledoc, and behaviour rules see lib/ and test/ inside an app" do
    commit = Commit.new(after: %{@app => "defmodule Shop.Cart do\n  def total, do: 0\nend\n"})
    assert_raise AssertCommit.Violation, ~r/Shop\.Cart\.total\/0/, fn -> assert_specs(commit) end
    assert_raise AssertCommit.Violation, ~r/Shop\.Cart/, fn -> assert_moduledoc(commit) end

    assert_raise AssertCommit.Violation, ~r/Shop\.Cart\.total\/0 \(added\)/, fn ->
      assert_behaviour_changes_tested(commit)
    end

    with_test =
      Commit.new(
        after: %{
          @app => "defmodule Shop.Cart do\n  def total, do: 0\nend\n",
          @test => "defmodule Shop.CartTest do\n  use ExUnit.Case\nend\n"
        }
      )

    assert_behaviour_changes_tested(with_test)
    assert_tested(with_test)
    assert behaviour_changed?(with_test, AssertCommit.Paths.lib())
  end

  test "dependencies and lockfiles are read from every nested mix.exs and mix.lock" do
    tree =
      Tree.from_map(%{
        "mix.exs" =>
          "defmodule Umbrella.MixProject do\n  def project, do: [apps_path: \"apps\", deps: deps()]\n  defp deps, do: []\nend\n",
        "apps/web/mix.exs" =>
          "defmodule Web.MixProject do\n  defp deps, do: [{:phoenix, \"~> 1.8\"}]\nend\n",
        "apps/data/mix.exs" =>
          "defmodule Data.MixProject do\n  defp deps, do: [{:ecto_sql, \"~> 3.13\"}]\nend\n",
        "mix.lock" =>
          ~s(%{"phoenix": {:hex, :phoenix, "1.8.0", "a", [:mix], [], "hexpm", "b"}, "ecto": {:hex, :ecto, "3.13.0", "a", [:mix], [], "hexpm", "b"}}\n),
        "apps/web/CHANGELOG.md" => "# Changelog\n",
        "deps/other/mix.exs" =>
          "defmodule Other.MixProject do\n  defp deps, do: [{:vendored_dep, \"~> 1.0\"}]\nend\n"
      })

    assert Enum.map(MixFile.all_deps(tree), & &1.name) == [:ecto_sql, :phoenix]
    assert Enum.sort(MixFile.all_locked(tree)) == [:ecto, :phoenix]

    config = Config.default(tree: tree, loaded?: fn _ -> false end)
    assert {Rules.Phoenix, :enabled, ["phoenix is a dependency"]} in config.detection
    assert {Rules.Ecto, :enabled, ["ecto is a dependency"]} in config.detection
    assert {Rules.Changelog, :enabled, ["CHANGELOG.md present"]} in config.detection
  end

  test "lock_in_sync compares dependencies across nested apps" do
    before = %{
      "apps/web/mix.exs" => "defmodule W do\n  defp deps, do: []\nend\n",
      "mix.lock" => "%{}\n"
    }

    after_files = %{
      "apps/web/mix.exs" => "defmodule W do\n  defp deps, do: [{:jason, \"~> 1.4\"}]\nend\n",
      "mix.lock" => "%{}\n"
    }

    commit = Commit.new(before: before, after: after_files)
    assert [%{name: :jason}] = deps_added(commit)

    assert_raise AssertCommit.Violation,
                 ~r/:jason was added to mix.exs but is not in mix.lock/,
                 fn -> assert_lock_in_sync(commit) end

    synced =
      Commit.new(
        before: before,
        after:
          Map.put(
            after_files,
            "mix.lock",
            ~s(%{"jason": {:hex, :jason, "1.4.4", "a", [:mix], [], "hexpm", "b"}}\n)
          )
      )

    assert_lock_in_sync(synced)
  end
end
