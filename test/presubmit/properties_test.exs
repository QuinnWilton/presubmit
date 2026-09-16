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

  describe "the facts cache" do
    # Whatever the cache holds, extraction must equal an uncached extraction of the same content at
    # the same path; identical blobs at different paths, and clears at any point, must not matter.
    property "is transparent" do
      source =
        one_of([
          constant("defmodule A do\n  def f, do: 1\nend\n"),
          constant("defmodule B do\nend\n"),
          constant("not elixir(")
        ])

      step =
        one_of([constant(:clear), tuple({member_of(["x/a.ex", "y/b.ex", "z/c.exs"]), source})])

      check all(steps <- list_of(step, min_length: 1, max_length: 12), max_runs: 40) do
        for s <- steps do
          case s do
            :clear ->
              Facts.clear_cache()

            {path, src} ->
              blob = "blob-#{:erlang.phash2(src)}"

              tree = %Presubmit.Tree{
                oid: "t-#{:erlang.phash2({path, src})}",
                paths: MapSet.new([path]),
                reader: fn _ -> {:ok, src} end,
                blobs: %{path => blob}
              }

              assert Facts.extract(tree, path) == Facts.from_source(src, path)
          end
        end
      end
    end
  end

  describe "the Phoenix router adapter" do
    alias Presubmit.Adapters.PhoenixRouter

    defp scope_segment,
      do: string(?a..?z, min_length: 1, max_length: 4) |> map(&String.capitalize/1)

    # A random nesting of scopes, each with a positional alias, an `alias:` option, `alias: false`,
    # or none, with one route at the innermost level.
    defp scopes_gen do
      list_of(
        one_of([
          tuple({:positional, scope_segment()}),
          tuple({:option, scope_segment()}),
          constant(:none),
          constant(:off)
        ]),
        max_length: 4
      )
    end

    property "plugs resolve to the concatenation of enclosing scope aliases, as Phoenix does" do
      check all(scopes <- scopes_gen(), plug <- scope_segment(), max_runs: 60) do
        {open, close} =
          Enum.map_reduce(scopes, [], fn s, _ ->
            {case s do
               {:positional, a} -> "scope \"/\", #{a} do"
               {:option, a} -> "scope \"/\", alias: #{a} do"
               :none -> "scope \"/\" do"
               :off -> "scope \"/\", alias: false do"
             end, nil}
          end)
          |> then(fn {opens, _} -> {opens, List.duplicate("end", length(opens))} end)

        source =
          ["defmodule R do", "use Phoenix.Router"] ++
            open ++ ["get \"/\", #{plug}, :index"] ++ close ++ ["end"]

        {:ok, %Facts{modules: [m]}} = Facts.from_source(Enum.join(source, "\n"))
        [route] = PhoenixRouter.extract(m).routes

        # Model: aliases accumulate until `alias: false` resets the prefix.
        prefix =
          Enum.reduce(scopes, [], fn
            {:positional, a}, acc -> acc ++ [a]
            {:option, a}, acc -> acc ++ [a]
            :none, acc -> acc
            :off, _acc -> []
          end)

        assert route.plug == Module.concat(Enum.map(prefix ++ [plug], &String.to_atom/1))
      end
    end
  end

  describe "RuleSet.expand/1" do
    alias Presubmit.{Rules, RuleSet}

    property "only:, except:, warn:, and in: compose as sets" do
      ids = Enum.map(Rules.Ecto.rules(), & &1.id)

      # A subset of the ids as a mask; `uniq_list_of` over a five-element pool exhausts its tries.
      subset =
        map(list_of(boolean(), length: length(ids)), fn mask ->
          for {id, true} <- Enum.zip(ids, mask), do: id
        end)

      check all(
              only <- one_of([constant(nil), filter(subset, &(&1 != []))]),
              except <- subset,
              warn <- subset,
              scoped? <- boolean()
            ) do
        opts =
          [except: except, warn: warn] ++
            if(only, do: [only: only], else: []) ++ if(scoped?, do: [in: ~r{^apps/}], else: [])

        rules = RuleSet.expand({Rules.Ecto, opts})
        selected = Enum.map(rules, & &1.id)

        assert selected == Enum.filter(ids, &((is_nil(only) or &1 in only) and &1 not in except))
        for r <- rules, do: assert(r.severity == if(r.id in warn, do: :warn, else: :error))
        for r <- rules, do: assert(r.scope != nil == scoped?)
        assert_raise ArgumentError, fn -> RuleSet.expand({Rules.Ecto, only: [:no_such_rule]}) end
      end
    end
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
