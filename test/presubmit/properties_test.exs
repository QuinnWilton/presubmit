defmodule Presubmit.PropertiesTest do
  @moduledoc "Invariants of the change model, the JSON encoder, and the rename substitution."
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Presubmit.Assertions

  alias Presubmit.{Commit, JSON, Query}
  alias Presubmit.Source.Facts

  defp path_gen, do: string(?a..?f, min_length: 1, max_length: 3) |> map(&"d/#{&1}.txt")
  defp text_gen, do: string(?x..?z, max_length: 3) |> map(&(&1 <> "\n"))
  defp files_gen, do: map_of(path_gen(), text_gen(), max_length: 6)

  describe "Commit.new/1" do
    property "classifies every path exactly once and reconstructs the after tree from the before tree" do
      check all(before <- files_gen(), after_files <- files_gen()) do
        commit = Commit.new(before: before, after: after_files)

        added = MapSet.new(Query.added(commit))
        removed = MapSet.new(Query.removed(commit))
        modified = MapSet.new(Query.modified(commit))

        assert added == MapSet.new(Map.keys(after_files) -- Map.keys(before))
        assert removed == MapSet.new(Map.keys(before) -- Map.keys(after_files))

        assert modified ==
                 MapSet.new(for {p, t} <- before, Map.get(after_files, p, t) != t, do: p)

        assert MapSet.disjoint?(added, removed) and MapSet.disjoint?(added, modified) and
                 MapSet.disjoint?(removed, modified)

        # Every change carries a diff that maps before to after (see Hunk's own property for the mechanics).
        for change <- commit.changes, change.status == :modified do
          assert change.additions == length(Presubmit.Hunk.added_lines(change.hunks))
        end
      end
    end
  end

  describe "JSON" do
    property "encodes any report-shaped term to something Jason decodes back" do
      scalar = one_of([integer(), boolean(), string(:printable), constant(nil)])

      check all(
              term <-
                map_of(
                  string(:alphanumeric, min_length: 1),
                  one_of([
                    scalar,
                    list_of(scalar, max_length: 3),
                    map_of(string(:alphanumeric, min_length: 1), scalar, max_length: 3)
                  ]),
                  max_length: 5
                )
            ) do
        assert term |> JSON.encode() |> IO.iodata_to_binary() |> Jason.decode!() == term
      end
    end

    property "atoms become strings and keys come out sorted" do
      check all(keys <- uniq_list_of(atom(:alphanumeric), min_length: 1, max_length: 6)) do
        map = Map.new(keys, &{&1, &1})
        decoded = map |> JSON.encode() |> IO.iodata_to_binary() |> Jason.decode!()
        assert decoded == Map.new(keys, &{Atom.to_string(&1), Atom.to_string(&1)})

        assert map |> JSON.encode() |> IO.iodata_to_binary() |> String.split(~s(":)) |> length() ==
                 length(keys) + 1
      end
    end
  end

  describe "assert_pure_move/1's rename substitution" do
    # A module name is a list of capitalised segments; deeper modules must survive a rename of their prefix.
    defp segment, do: string(?a..?z, min_length: 1, max_length: 4) |> map(&String.capitalize/1)

    defp module_name,
      do: list_of(segment(), min_length: 1, max_length: 3) |> map(&Module.concat/1)

    property "renaming a module and rewriting its callers is a pure move; the same edit plus a body change is not" do
      check all(
              old <- module_name(),
              suffix <- segment(),
              deeper <- segment(),
              max_runs: 40
            ) do
        # `new` differs from `old` in its first segment, so it is neither `old` nor `old`'s child.
        [first | rest] = Module.split(old)
        new = Module.concat([first <> suffix <> "Renamed" | rest])
        child = Module.concat([old, deeper])

        before = %{
          "lib/a.ex" => "defmodule #{inspect(old)} do\n  def f(x), do: x\nend\n",
          "lib/c.ex" =>
            "defmodule #{inspect(child)} do\n  def g, do: #{inspect(old)}.f(1)\nend\n",
          "lib/b.ex" =>
            "defmodule Caller0 do\n  alias #{inspect(old)}\n  def h, do: #{inspect(old)}.f(#{inspect(child)}.g()) + #{last(old)}.f(2)\nend\n"
        }

        after_files = %{
          "lib/a.ex" => "defmodule #{inspect(new)} do\n  def f(x), do: x\nend\n",
          "lib/c.ex" =>
            "defmodule #{inspect(child)} do\n  def g, do: #{inspect(new)}.f(1)\nend\n",
          "lib/b.ex" =>
            "defmodule Caller0 do\n  alias #{inspect(new)}\n  def h, do: #{inspect(new)}.f(#{inspect(child)}.g()) + #{last(new)}.f(2)\nend\n"
        }

        commit = Commit.new(before: before, after: after_files)
        # The child module keeps its name even though its prefix was renamed.
        assert Query.modules_renamed(commit) == [{old, new}]
        assert Query.modules_added(commit) == [] and Query.modules_removed(commit) == []
        assert_pure_move(commit)

        edited =
          Commit.new(
            before: before,
            after:
              Map.put(
                after_files,
                "lib/c.ex",
                "defmodule #{inspect(child)} do\n  def g, do: #{inspect(new)}.f(2)\nend\n"
              )
          )

        assert_raise Presubmit.Violation, fn -> assert_pure_move(edited) end
      end
    end

    defp last(module), do: module |> Module.split() |> List.last()
  end

  describe "Facts" do
    # Reserved words (`fn`, `do`, `end`, ...) are not valid function names.
    @reserved ~w(fn do end else after rescue catch true false nil and or not in when)

    property "every def contributes exactly the arities its defaults generate" do
      check all(
              name <- filter(string(?a..?z, min_length: 1, max_length: 5), &(&1 not in @reserved)),
              required <- integer(0..3),
              defaults <- integer(0..3)
            ) do
        args = Enum.map(1..required//1, &"a#{&1}") ++ Enum.map(1..defaults//1, &"d#{&1} \\\\ nil")
        source = "defmodule P do\n  def #{name}(#{Enum.join(args, ", ")}), do: :ok\nend\n"
        {:ok, %Facts{modules: [m]}} = Facts.from_source(source)

        assert Enum.map(m.functions, & &1.arity) ==
                 Enum.to_list(required..(required + defaults)//1)
      end
    end
  end
end
