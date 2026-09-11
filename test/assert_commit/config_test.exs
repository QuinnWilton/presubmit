defmodule AssertCommit.ConfigTest do
  use ExUnit.Case, async: true

  alias AssertCommit.{Config, Rules}

  @moduletag :tmp_dir

  test "default/0 enables every built-in set" do
    config = Config.default()
    assert config.sets == Config.builtin_sets()
    assert Enum.map(config.rules, & &1.id) |> Enum.uniq() |> length() > 20
    assert Rules.Phoenix in Enum.map(config.rules, & &1.set)
  end

  test "load!/1 falls back to the default when no file exists", %{tmp_dir: dir} do
    assert Config.load!(repo: dir).path == nil
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
