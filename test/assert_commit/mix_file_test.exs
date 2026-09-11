defmodule AssertCommit.MixFileTest do
  use ExUnit.Case, async: true

  alias AssertCommit.{MixFile, Tree}

  @mix_exs """
  defmodule Demo.MixProject do
    use Mix.Project
    @version "1.2.3"
    def project, do: [app: :demo, version: @version, deps: deps()]

    defp deps do
      [
        {:jason, "~> 1.4"},
        {:ecto_sql, "~> 3.11", only: :test},
        {:pentiment, path: "../pentiment"},
        {:plug, github: "elixir-plug/plug"}
      ]
    end
  end
  """

  @mix_lock """
  %{
    "jason": {:hex, :jason, "1.4.4", "a", [:mix], [], "hexpm", "b"},
    "ecto_sql": {:hex, :ecto_sql, "3.11.0", "a", [:mix], [], "hexpm", "b"},
  }
  """

  test "deps with every declaration shape" do
    deps = MixFile.deps(Tree.from_map(%{"mix.exs" => @mix_exs}))

    assert Enum.map(deps, &{&1.name, &1.requirement, &1.opts}) == [
             {:jason, "~> 1.4", []},
             {:ecto_sql, "~> 3.11", [only: :test]},
             {:pentiment, nil, [path: "../pentiment"]},
             {:plug, nil, [github: "elixir-plug/plug"]}
           ]
  end

  test "version from @version or a literal" do
    assert MixFile.version(Tree.from_map(%{"mix.exs" => @mix_exs})) == "1.2.3"

    assert MixFile.version(
             Tree.from_map(%{
               "mix.exs" => "defmodule M do\n  def project, do: [version: \"0.1.0\"]\nend\n"
             })
           ) == "0.1.0"

    assert MixFile.version(Tree.from_map(%{})) == nil
  end

  test "locked package names" do
    assert MixFile.locked(Tree.from_map(%{"mix.lock" => @mix_lock})) == [:jason, :ecto_sql]
    assert MixFile.locked(Tree.from_map(%{})) == []
  end
end
