defmodule Presubmit.MixFileTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Presubmit.{MixFile, Pattern, Tree}

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

  describe "elixirc_paths/2" do
    defp elixirc_paths(project_body, rest \\ "") do
      MixFile.elixirc_paths(
        Tree.from_map(%{
          "mix.exs" => """
          defmodule P.MixProject do
            use Mix.Project
            def project, do: #{project_body}
          #{rest}
          end
          """
        })
      )
    end

    test "resolves the :prod clause of the generated elixirc_paths(Mix.env()) helper" do
      helper = """
        defp elixirc_paths(:test), do: ["lib", "test/support"]
        defp elixirc_paths(_), do: ["lib"]
      """

      assert elixirc_paths("[app: :p, elixirc_paths: elixirc_paths(Mix.env())]", helper) ==
               ["lib"]

      # The `Mix.env` call without parentheses is the same call.
      assert elixirc_paths("[elixirc_paths: elixirc_paths(Mix.env)]", helper) == ["lib"]
    end

    test "is Mix's default, lib, when the project does not say" do
      assert elixirc_paths("[app: :p]") == ["lib"]
      assert MixFile.elixirc_paths(Tree.from_map(%{})) == ["lib"]
      assert MixFile.elixirc_paths(Tree.from_map(%{"mix.exs" => "defmodule ("})) == ["lib"]
    end

    test "is empty for an umbrella root, which compiles nothing itself" do
      assert elixirc_paths(~s([apps_path: "apps", elixirc_paths: ["lib"]])) == []
    end

    test "reads literals, ++, module attributes, if, and guarded clauses" do
      assert elixirc_paths(~s([elixirc_paths: ["src", "gen"]])) == ["src", "gen"]
      assert elixirc_paths(~s([elixirc_paths: ["src"] ++ ["gen"]])) == ["src", "gen"]
      assert elixirc_paths("[elixirc_paths: @paths]", ~s(@paths ["src"])) == ["src"]

      assert elixirc_paths(
               ~s|[elixirc_paths: if(Mix.env() == :test, do: ["lib", "t"], else: ["lib"])]|
             ) == ["lib"]

      assert elixirc_paths(
               ~s|[elixirc_paths: if(not (Mix.env() != :prod), do: ["src"], else: ["lib"])]|
             ) == ["src"]

      assert elixirc_paths("[elixirc_paths: paths(Mix.env())]", """
               defp paths(env) when env in [:dev, :test], do: ["lib", "dev"]
               defp paths(env) when not (env == :bench or env == :docs), do: ["lib", "prod"]
             """) == ["lib", "prod"]

      assert elixirc_paths("[elixirc_paths: paths(Mix.env())]", """
               defp paths(:prod = env), do: base(env) ++ ["extra"]
               defp base(_), do: @base
               @base ["lib"]
             """) == ["lib", "extra"]
    end

    test "falls back to lib rather than guess at what it cannot read" do
      # A function call it does not know.
      assert elixirc_paths(~s|[elixirc_paths: Path.wildcard("lib*")]|) == ["lib"]
      # A value that is not a list of strings.
      assert elixirc_paths("[elixirc_paths: :lib]") == ["lib"]
      # A recursive helper.
      assert elixirc_paths("[elixirc_paths: paths()]", "defp paths, do: paths()") == ["lib"]

      # A clause head it cannot match stops resolution instead of falling through to a later
      # clause, which might not be the one Mix would pick.
      assert elixirc_paths("[elixirc_paths: paths(Mix.env())]", """
               defp paths(env) when is_atom(env), do: ["src"]
               defp paths(_), do: ["other"]
             """) == ["lib"]

      assert elixirc_paths("[elixirc_paths: paths(Mix.env())]", """
               defp paths(%{}), do: ["src"]
               defp paths(_), do: ["other"]
             """) == ["lib"]
    end

    property "picks the first clause that matches :prod, as Mix would" do
      env = member_of([:dev, :test, :prod, :bench])
      paths = list_of(member_of(["lib", "src", "test/support", "dev", "gen"]), max_length: 3)

      check all(
              clauses <- list_of(tuple({one_of([env, constant(:_)]), paths}), max_length: 5),
              fallback <- paths
            ) do
        helper =
          (clauses ++ [{:_, fallback}])
          |> Enum.map_join("\n", fn
            {:_, paths} -> "  defp paths(_env), do: #{inspect(paths)}"
            {env, paths} -> "  defp paths(#{inspect(env)}), do: #{inspect(paths)}"
          end)

        expected =
          Enum.find_value(clauses, fallback, fn {pattern, paths} ->
            if pattern in [:_, :prod], do: paths
          end)

        assert elixirc_paths("[elixirc_paths: paths(Mix.env())]", helper) == expected
      end
    end
  end

  describe "shipped_source/1" do
    @argus_style """
    defmodule A.MixProject do
      def project, do: [elixirc_paths: elixirc_paths(Mix.env())]
      defp elixirc_paths(:test), do: ["lib", "test/fixtures", "test/support"]
      defp elixirc_paths(_), do: ["lib"]
    end
    """

    defp shipped?(files, path),
      do: Pattern.matches?(path, MixFile.shipped_source(Tree.from_map(files)))

    test "covers .ex files under the :prod elixirc_paths, not test support or fixtures" do
      files = %{"mix.exs" => @argus_style}

      assert shipped?(files, "lib/a.ex")
      assert shipped?(files, "lib/a/b.ex")
      refute shipped?(files, "test/support/call_count.ex")
      refute shipped?(files, "test/fixtures/live_endpoint_fixture.ex")
      refute shipped?(files, "test/a_test.exs")
      refute shipped?(files, "mix.exs")
      # Mix compiles only .ex files from a directory.
      refute shipped?(files, "lib/script.exs")
      refute shipped?(files, "library/a.ex")
    end

    test "follows paths outside lib" do
      files = %{
        "mix.exs" =>
          ~s(defmodule P do\n  def project, do: [elixirc_paths: ["src", "./gen/", "one.ex"]]\nend\n)
      }

      assert shipped?(files, "src/a.ex")
      assert shipped?(files, "gen/b.ex")
      assert shipped?(files, "one.ex")
      refute shipped?(files, "lib/a.ex")
      refute shipped?(files, "two.ex")
    end

    test "joins each project's paths to its directory" do
      files = %{
        "mix.exs" => ~s(defmodule U do\n  def project, do: [apps_path: "apps"]\nend\n),
        "apps/a/mix.exs" => @argus_style,
        "apps/b/mix.exs" =>
          ~s(defmodule B do\n  def project, do: [elixirc_paths: ["src", "../shared"]]\nend\n),
        "deps/dep/mix.exs" => "defmodule D do\nend\n",
        "test/fixtures/proj/mix.exs" => "defmodule F do\nend\n"
      }

      assert shipped?(files, "apps/a/lib/a.ex")
      refute shipped?(files, "apps/a/test/support/case.ex")
      assert shipped?(files, "apps/b/src/b.ex")
      assert shipped?(files, "apps/shared/s.ex")
      refute shipped?(files, "apps/b/lib/b.ex")
      # The umbrella root compiles nothing, vendored deps are not the project, and a mix.exs
      # under test/ describes a fixture.
      refute shipped?(files, "lib/root.ex")
      refute shipped?(files, "deps/dep/lib/d.ex")
      refute shipped?(files, "test/fixtures/proj/lib/f.ex")
    end

    test "is every .ex file when a project compiles its own directory" do
      files = %{"mix.exs" => ~s(defmodule P do\n  def project, do: [elixirc_paths: ["."]]\nend\n)}
      assert shipped?(files, "a.ex")
      assert shipped?(files, "test/support/a.ex")
      refute shipped?(files, "a.exs")
    end

    test "is the conventional lib/ directories when the tree has no mix.exs" do
      assert shipped?(%{}, "lib/a.ex")
      assert shipped?(%{}, "apps/shop/lib/shop.ex")
      refute shipped?(%{}, "test/support/a.ex")
    end
  end
end
