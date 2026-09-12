defmodule AssertCommit.ConfigTest do
  use ExUnit.Case, async: true

  alias AssertCommit.{Config, Rules}

  @moduletag :tmp_dir

  describe "default/1" do
    alias AssertCommit.{Commit, Tree}

    defp enabled(config), do: for({m, :enabled, _} <- config.detection, do: m)
    defp disabled(config), do: for({m, :disabled, _} <- config.detection, do: m)

    test "with nothing detected, enables the sets that apply to any project" do
      config = Config.default(loaded?: fn _ -> false end)

      assert enabled(config) == [
               Rules.Elixir,
               Rules.OTP,
               Rules.ExUnit,
               Rules.Mix,
               Rules.Message,
               Rules.Hygiene,
               Rules.Shape
             ]

      assert disabled(config) == [Rules.Phoenix, Rules.Ecto, Rules.Changelog]
      assert config.path == nil

      ids = Enum.map(config.rules, &{&1.set, &1.id})
      assert {Rules.ExUnit, :behaviour_changes_tested} in ids
      refute {Rules.ExUnit, :tested} in ids
      assert {Rules.Message, :no_fixup} in ids
      refute {Rules.Message, :subject} in ids
    end

    test "enables Phoenix and Ecto from the examined tree's mix.exs, and Changelog from its files" do
      tree =
        Tree.from_map(%{
          "mix.exs" =>
            "defmodule M do\n  def project, do: [deps: deps()]\n  defp deps, do: [{:phoenix, \"~> 1.8\"}, {:ecto_sql, \"~> 3.13\"}, {:ecto, \"~> 3.13\"}]\nend\n",
          "CHANGELOG.md" => "# Changelog\n"
        })

      config = Config.default(tree: tree, loaded?: fn _ -> false end)
      assert disabled(config) == []
      assert {Rules.Phoenix, :enabled, ["phoenix is a dependency"]} in config.detection
      assert {Rules.Ecto, :enabled, ["ecto is a dependency"]} in config.detection
      assert {Rules.Changelog, :enabled, ["CHANGELOG.md present"]} in config.detection

      assert Config.default(
               commit: Commit.new(after: %{"CHANGELOG.md" => ""}),
               loaded?: fn _ -> false end
             )
             |> enabled()
             |> Enum.member?(Rules.Changelog)
    end

    test "a locked transitive dependency counts, so ecto_sql projects get the Ecto rules" do
      tree =
        Tree.from_map(%{
          "mix.exs" => "defmodule M do\n  defp deps, do: [{:ecto_sql, \"~> 3.13\"}]\nend\n",
          "mix.lock" => ~s(%{"ecto": {:hex, :ecto, "3.13.0", "a", [:mix], [], "hexpm", "b"}}\n)
        })

      config = Config.default(tree: tree, loaded?: fn _ -> false end)
      assert {Rules.Ecto, :enabled, ["ecto is a dependency"]} in config.detection
    end

    test "enables Phoenix and Ecto when their modules are loaded in the VM" do
      config = Config.default(loaded?: &(&1 in [Phoenix.Router, Ecto.Schema]))
      assert {Rules.Phoenix, :enabled, ["Phoenix.Router loaded"]} in config.detection
      assert {Rules.Ecto, :enabled, ["Ecto.Schema loaded"]} in config.detection
      assert Rules.Phoenix in Enum.map(config.rules, & &1.set)
    end

    test "builtin_sets/0 lists every set the defaults consider" do
      assert Config.builtin_sets() == [
               Rules.Elixir,
               Rules.Phoenix,
               Rules.Ecto,
               Rules.OTP,
               Rules.ExUnit,
               Rules.Mix,
               Rules.Changelog,
               Rules.Message,
               Rules.Hygiene,
               Rules.Shape
             ]
    end
  end

  test "load!/1 falls back to the default when no file exists", %{tmp_dir: dir} do
    config = Config.load!(repo: dir, loaded?: fn _ -> false end)
    assert config.path == nil
    assert config.detection != []
  end

  test "load!/1 evaluates .assert_commit.exs, including inline rule sets", %{tmp_dir: dir} do
    File.write!(Path.join(dir, ".assert_commit.exs"), """
    defmodule ConfigTestRules do
      use AssertCommit.RuleSet
      rule :custom, "custom", fn _ -> :ok end
    end

    [
      {AssertCommit.Rules.Ecto, except: [:migrations_reversible]},
      {AssertCommit.Rules.Shape, max_files: 5},
      ConfigTestRules
    ]
    """)

    config = Config.load!(repo: dir)
    assert config.path == Path.join(dir, ".assert_commit.exs")
    ids = Enum.map(config.rules, &{&1.set, &1.id})
    refute {Rules.Ecto, :migrations_reversible} in ids
    assert {Rules.Ecto, :indexes_concurrent} in ids
    assert {ConfigTestRules, :custom} in ids
    assert Enum.find(config.rules, &(&1.id == :max_files)).opts == [max_files: 5]
  end

  test "load!/1 reports unknown rules with the file name", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "rules.exs"), "[{AssertCommit.Rules.Ecto, only: [:nope]}]")
    error = assert_raise Config.Error, fn -> Config.load!(repo: dir, config: "rules.exs") end
    assert Exception.message(error) =~ "rules.exs: AssertCommit.Rules.Ecto has no rule :nope"
  end

  test "load!/1 rejects a file that is not a list, and a missing explicit file", %{tmp_dir: dir} do
    File.write!(Path.join(dir, ".assert_commit.exs"), "%{rules: []}")

    assert_raise Config.Error, ~r/must evaluate to a list of rule sets/, fn ->
      Config.load!(repo: dir)
    end

    assert_raise Config.Error, ~r/does not exist/, fn ->
      Config.load!(repo: dir, config: "missing.exs")
    end
  end
end
