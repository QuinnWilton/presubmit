defmodule Presubmit.Source.FactsTest do
  use ExUnit.Case, async: true

  alias Presubmit.Source.Facts
  alias Presubmit.Source.Facts.{Function, Module}

  defp facts!(source) do
    {:ok, facts} = Facts.from_source(source, "lib/a.ex")
    facts
  end

  defp module!(source), do: facts!(source).modules |> List.last()

  describe "modules" do
    test "top-level and nested, with nested names prefixed" do
      names =
        facts!("defmodule A do\n  defmodule B do\n  end\nend\ndefmodule C.D do\nend\n").modules
        |> Enum.map(& &1.name)

      assert names == [A, A.B, C.D]
    end

    test "unparseable source is an error" do
      assert {:error, _} = Facts.from_source("defmodule A do")
    end
  end

  describe "functions" do
    test "def and defmacro are public; defp is not; guards fold into one function; defaults expand arities" do
      m =
        module!("""
        defmodule A do
          def one(x) when is_integer(x), do: x
          def one(x), do: x
          def two(a, b \\\\ 1, c \\\\ 2), do: {a, b, c}
          defmacro three(ast), do: ast
          defp hidden, do: :no
        end
        """)

      assert Enum.map(m.functions, &{&1.name, &1.arity, &1.kind}) ==
               [
                 {:one, 1, :def},
                 {:two, 1, :def},
                 {:two, 2, :def},
                 {:two, 3, :def},
                 {:three, 1, :defmacro},
                 {:hidden, 0, :defp}
               ]

      assert Enum.map(Module.public_functions(m), &Function.key/1) == [
               {A, :one, 1},
               {A, :two, 1},
               {A, :two, 2},
               {A, :two, 3},
               {A, :three, 1}
             ]

      assert length(Enum.find(m.functions, &(&1.name == :one)).clauses) == 2
    end

    test "@spec, @doc, and @deprecated attach to the following function" do
      m =
        module!("""
        defmodule A do
          @doc "docs"
          @spec f(integer()) :: integer()
          def f(x), do: x

          @doc false
          @deprecated "use f/1"
          def g(x), do: x

          @spec h(t) :: t when t: term()
          def h(x), do: x

          def i, do: 1
        end
        """)

      by_name = Map.new(m.functions, &{&1.name, &1})
      assert %{spec?: true, doc: :present, deprecated?: false} = by_name.f
      assert %{spec?: false, doc: false, deprecated?: true} = by_name.g
      assert %{spec?: true, doc: nil} = by_name.h
      assert %{spec?: false, doc: nil, deprecated?: false} = by_name.i
    end

    test "a spec for the full arity covers default-generated arities; @impl is recorded" do
      m =
        module!("""
        defmodule A do
          @spec f(integer(), integer()) :: integer()
          def f(a, b \\\\ 1), do: a + b

          @impl true
          def init(state), do: {:ok, state}
        end
        """)

      assert Enum.map(m.functions, &{&1.name, &1.arity, &1.spec?, &1.impl?}) ==
               [{:f, 1, true, false}, {:f, 2, true, false}, {:init, 1, false, true}]
    end

    test "defdelegate is a public function; @moduledoc false hides a module's functions from the API" do
      m =
        module!("""
        defmodule A do
          @moduledoc false
          defdelegate size(x), to: Enum, as: :count
          def f, do: 1
        end
        """)

      assert [
               %{name: :size, arity: 1, kind: :def, delegate?: true, module_hidden?: true},
               %{name: :f, module_hidden?: true}
             ] = m.functions

      assert Enum.all?(m.functions, &Function.public?/1)
      refute Enum.any?(m.functions, &Function.api?/1)
    end

    test "clause hashes ignore line metadata and alias spelling, but not code" do
      a = module!("defmodule A do\n  def f, do: 1\nend\n")
      b = module!("defmodule A do\n\n\n  def f, do: 1\nend\n")
      c = module!("defmodule A do\n  def f, do: 2\nend\n")
      assert hd(a.functions).clauses == hd(b.functions).clauses
      refute hd(a.functions).clauses == hd(c.functions).clauses

      full = module!("defmodule A do\n  def f, do: X.Y.g()\nend\n")
      aliased = module!("defmodule A do\n  alias X.Y\n  def f, do: Y.g()\nend\n")
      other = module!("defmodule A do\n  alias X.Z\n  def f, do: Z.g()\nend\n")
      assert hd(full.functions).clauses == hd(aliased.functions).clauses
      refute hd(full.functions).clauses == hd(other.functions).clauses
    end
  end

  describe "attributes and directives" do
    test "uses, behaviours, moduledoc, struct" do
      m =
        module!("""
        defmodule A do
          @moduledoc false
          @behaviour GenServer
          use Ecto.Schema
          use MyAppWeb, :controller
          @enforce_keys [:id]
          defstruct [:id, name: nil]
        end
        """)

      assert m.moduledoc == false
      assert m.behaviours == [GenServer]
      assert Module.uses?(m, Ecto.Schema)
      assert Module.uses?(m, MyAppWeb, :controller)
      refute Module.uses?(m, MyAppWeb, :router)
      assert m.struct == %{fields: [:id, :name], enforce_keys: [:id]}
    end
  end

  describe "references and aliases" do
    test "resolve plain, multi, and as: aliases" do
      m =
        module!("""
        defmodule A do
          alias Demo.Accounts
          alias Demo.{Blog, Repo.Internal}
          alias Demo.Long.Name, as: Short
          def f, do: {Accounts.User, Blog.Post, Internal.x(), Short.y(), Other.Thing, __MODULE__}
        end
        """)

      assert m.aliases == %{
               Accounts: Demo.Accounts,
               Blog: Demo.Blog,
               Internal: Demo.Repo.Internal,
               Short: Demo.Long.Name
             }

      for ref <- [
            Demo.Accounts.User,
            Demo.Blog.Post,
            Demo.Repo.Internal,
            Demo.Long.Name,
            Other.Thing,
            A
          ],
          do: assert(ref in m.references)
    end

    test "literal module atoms count as references" do
      assert Foo.Bar in module!("defmodule A do\n  @mod :\"Elixir.Foo.Bar\"\nend\n").references
    end
  end

  describe "caching" do
  end
end

defmodule Presubmit.Source.FactsRobustnessTest do
  use ExUnit.Case, async: true

  alias Presubmit.Source.Facts

  test "modules without a literal name are skipped, and literal modules nested in them are kept" do
    {:ok, facts} =
      Facts.from_source("""
      defmodule Outer do
        defmodule __MODULE__.Dynamic do
          defmodule Inner do
            def f, do: 1
          end
        end

        defmacro make(name) do
          quote do
            defmodule unquote(name) do
              def g, do: 2
            end
          end
        end
      end
      """)

    assert Enum.map(facts.modules, & &1.name) == [Outer, Outer.Inner]
  end

  test "a `defmodule` whose body is not a block is still extracted" do
    assert {:ok, %Facts{modules: [%{name: A, functions: [%{name: :f}]}]}} =
             Facts.from_source("defmodule A, do: (def f, do: 1)")
  end
end
