defmodule Presubmit.QueryTest do
  use ExUnit.Case, async: true

  import Presubmit.Query

  alias Presubmit.Commit

  # The shape argus and Phoenix projects use: test support compiled only under MIX_ENV=test.
  @mix_exs """
  defmodule P.MixProject do
    use Mix.Project
    def project, do: [app: :p, elixirc_paths: elixirc_paths(Mix.env())]
    defp elixirc_paths(:test), do: ["lib", "test/support"]
    defp elixirc_paths(_), do: ["lib"]
  end
  """

  defp module(name, functions),
    do: "defmodule #{name} do\n" <> Enum.map_join(functions, &"  def #{&1}, do: 1\n") <> "end\n"

  describe "public_api_diff/1" do
    test "does not count functions added to or removed from test support" do
      commit =
        Commit.new(
          before: %{
            "mix.exs" => @mix_exs,
            "test/support/fixture_cover.ex" => module("P.Test.FixtureCover", ["code"])
          },
          after: %{
            "mix.exs" => @mix_exs,
            "test/support/fixture_cover.ex" => module("P.Test.FixtureCover", ["beams"]),
            "test/support/call_count.ex" => module("P.Test.CallCount", ["calls(m)"])
          }
        )

      assert [_ | _] = functions_added(commit)
      assert public_api_diff(commit) == %{added: [], removed: []}
      refute public_api_changed?(commit)
    end

    test "counts functions added to and removed from lib/ beside test support" do
      commit =
        Commit.new(
          before: %{
            "mix.exs" => @mix_exs,
            "lib/p.ex" => module("P", ["old"]),
            "test/support/case.ex" => module("P.Case", ["setup_repo"])
          },
          after: %{
            "mix.exs" => @mix_exs,
            "lib/p.ex" => module("P", ["new"]),
            "test/support/case.ex" => module("P.Case", ["setup_other"])
          }
        )

      assert public_api_diff(commit) == %{added: [{P, :new, 0}], removed: [{P, :old, 0}]}
      assert public_api_changed?(commit)
    end

    test "follows elixirc_paths outside lib/" do
      mix_exs = """
      defmodule P.MixProject do
        def project, do: [elixirc_paths: if(Mix.env() == :test, do: ["src", "spec/helpers"], else: ["src"])]
      end
      """

      commit =
        Commit.new(
          after: %{
            "mix.exs" => mix_exs,
            "src/p.ex" => module("P", ["shipped"]),
            "lib/stray.ex" => module("P.Stray", ["not_compiled"]),
            "spec/helpers/h.ex" => module("P.Helpers", ["helper"])
          }
        )

      assert public_api_diff(commit) == %{added: [{P, :shipped, 0}], removed: []}
    end

    test "reads each umbrella app's own elixirc_paths" do
      commit =
        Commit.new(
          after: %{
            "mix.exs" => ~s(defmodule U do\n  def project, do: [apps_path: "apps"]\nend\n),
            "apps/shop/mix.exs" => @mix_exs,
            "apps/shop/lib/shop.ex" => module("Shop", ["total"]),
            "apps/shop/test/support/shop_case.ex" => module("Shop.Case", ["cart"])
          }
        )

      assert public_api_diff(commit) == %{added: [{Shop, :total, 0}], removed: []}
    end

    test "judges a removal by the mix.exs before the change and an addition by the one after" do
      ships = &~s(defmodule P do\n  def project, do: [elixirc_paths: #{inspect(&1)}]\nend\n)

      # The commit moves the project from lib/ to src/ and drops a module on the way.
      commit =
        Commit.new(
          before: %{"mix.exs" => ships.(["lib"]), "lib/gone.ex" => module("P.Gone", ["f"])},
          after: %{"mix.exs" => ships.(["src"]), "src/new.ex" => module("P.New", ["g"])}
        )

      assert public_api_diff(commit) == %{added: [{P.New, :g, 0}], removed: [{P.Gone, :f, 0}]}
    end
  end

  describe "the :shipped pattern" do
    test "selects functions and modules from the files the project ships" do
      commit =
        Commit.new(
          before: %{"mix.exs" => @mix_exs, "test/support/old.ex" => module("P.Old", ["x"])},
          after: %{
            "mix.exs" => @mix_exs,
            "lib/p.ex" => module("P", ["f"]),
            "test/support/case.ex" => module("P.Case", ["g"])
          }
        )

      assert modules_added(commit, :shipped) == [P]
      assert Enum.map(functions_added(commit, :shipped), & &1.name) == [:f]
      assert modules_removed(commit, :shipped) == []
      assert functions_removed(commit, :shipped) == []
      assert modules_removed(commit) == [P.Old]
      assert Enum.map(function_changes(commit, :shipped).added, & &1.name) == [:f]
      assert behaviour_changed?(commit, :shipped)
    end
  end
end
