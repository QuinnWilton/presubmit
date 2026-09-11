defmodule AssertCommit.Source.DiffTest do
  use ExUnit.Case, async: true

  alias AssertCommit.Commit
  alias AssertCommit.Source.Diff

  defp diff(before, after_files, opts \\ []),
    do: Commit.new([before: before, after: after_files] ++ opts).elixir

  test "modules added, removed, and modified" do
    d =
      diff(
        %{
          "lib/a.ex" => "defmodule A do\n  def f, do: 1\nend\n",
          "lib/b.ex" => "defmodule B do\nend\n"
        },
        %{
          "lib/a.ex" => "defmodule A do\n  def f, do: 2\nend\n",
          "lib/c.ex" => "defmodule C do\nend\n"
        }
      )

    assert Enum.map(d.modules.added, & &1.name) == [C]
    assert Enum.map(d.modules.removed, & &1.name) == [B]
    assert [{%{name: A}, %{name: A}}] = d.modules.modified
    assert [{_, %{name: :f}}] = d.functions.body_changed
  end

  test "a module renamed with its public surface intact is a rename, not add + remove" do
    d =
      diff(%{"lib/a.ex" => "defmodule A do\n  def f, do: 1\nend\n"}, %{
        "lib/b.ex" => "defmodule B do\n  def f, do: 1\nend\n"
      })

    assert [{%{name: A}, %{name: B}}] = d.modules.renamed
    assert d.modules.added == [] and d.modules.removed == []
    assert d.functions.added == [] and d.functions.removed == []
    refute Diff.behaviour_changed?(d)
  end

  test "a surface-less module is a rename only when git renamed the file" do
    before = %{"lib/a.ex" => "defmodule A do\nend\n"}
    after_files = %{"lib/b.ex" => "defmodule B do\nend\n"}

    assert [{%{name: A}, %{name: B}}] =
             diff(before, after_files, renames: [{"lib/a.ex", "lib/b.ex"}]).modules.renamed

    assert [%{name: B}] = diff(before, after_files).modules.added
  end

  test "functions: added, removed, spec added, spec removed, public API" do
    d =
      diff(
        %{
          "lib/a.ex" =>
            "defmodule A do\n  @spec f() :: 1\n  def f, do: 1\n  def g, do: 1\n  def h, do: 1\nend\n"
        },
        %{
          "lib/a.ex" =>
            "defmodule A do\n  def f, do: 1\n  @spec g() :: 1\n  def g, do: 1\n  def i, do: 1\n  defp j, do: 1\nend\n"
        }
      )

    assert Enum.map(d.functions.added, & &1.name) == [:i, :j]
    assert Enum.map(d.functions.removed, & &1.name) == [:h]
    assert Enum.map(d.functions.spec_added, & &1.name) == [:g]
    assert Enum.map(d.functions.spec_removed, & &1.name) == [:f]
    assert Diff.public_added(d) == [{A, :i, 0}]
    assert Diff.public_removed(d) == [{A, :h, 0}]
    assert Diff.public_api_changed?(d)
  end

  test "struct fields added and removed" do
    d =
      diff(%{"lib/a.ex" => "defmodule A do\n  defstruct [:x, :y]\nend\n"}, %{
        "lib/a.ex" => "defmodule A do\n  defstruct [:x, :z]\nend\n"
      })

    assert d.structs == %{fields_added: [{A, :z}], fields_removed: [{A, :y}]}
  end

  test "docs and formatting are not behaviour changes" do
    d =
      diff(%{"lib/a.ex" => "defmodule A do\n  def f, do: 1\nend\n"}, %{
        "lib/a.ex" =>
          "defmodule A do\n  @moduledoc \"A\"\n\n  @doc \"f\"\n  def f do\n    1\n  end\nend\n"
      })

    refute Diff.behaviour_changed?(d)
  end

  test "unparseable files are reported, not ignored silently" do
    d = diff(%{}, %{"lib/a.ex" => "defmodule A do"})
    assert [{"lib/a.ex", _}] = d.unparsed
  end
end
