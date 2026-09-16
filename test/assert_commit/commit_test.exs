defmodule AssertCommit.CommitTest do
  use ExUnit.Case, async: true

  import AssertCommit.Assertions
  import AssertCommit.Query

  alias AssertCommit.{Commit, FileChange}

  describe "new/1 (synthetic change sets)" do
    test "classifies additions, deletions, and modifications" do
      commit =
        Commit.new(
          before: %{"keep" => "k\n", "gone" => "g\n", "edit" => "1\n"},
          after: %{"keep" => "k\n", "new" => "n\n", "edit" => "2\n"},
          message: "Subject"
        )

      assert Enum.map(commit.changes, &{&1.status, &1.path}) == [
               {:modified, "edit"},
               {:deleted, "gone"},
               {:added, "new"}
             ]

      assert added_lines(commit) == [{"edit", 1, "2"}, {"new", 1, "n"}]
      assert commit.source == :synthetic
    end

    test "declared renames are renames; undeclared moves are delete plus add" do
      before = %{"a" => "x\n"}
      after_files = %{"b" => "x\n"}

      assert [%FileChange{status: :renamed, old_path: "a", path: "b", additions: 0}] =
               Commit.new(before: before, after: after_files, renames: [{"a", "b"}]).changes

      assert [{:deleted, "a"}, {:added, "b"}] =
               Commit.new(before: before, after: after_files).changes
               |> Enum.map(&{&1.status, &1.path})
    end

    test "assertions work identically on synthetic commits" do
      commit =
        Commit.new(
          after: %{"lib/x.ex" => "defmodule X do\n  def f, do: IO.inspect(1)\nend\n"},
          message: "[x] add f"
        )

      assert modules_added(commit) == [X]
      assert public_api_diff(commit) == %{added: [{X, :f, 0}], removed: []}
      assert_scope_matches_paths(commit, ~r/^\[(\w+)\]/, fn scope -> ~r{^lib/#{scope}\.ex$} end)
      assert_raise AssertCommit.Violation, fn -> refute_added_lines(commit, ~r/IO\.inspect/) end
      assert_raise AssertCommit.Violation, fn -> assert_specs(commit) end

      exempt =
        Commit.new(
          after: %{
            "lib/y.ex" =>
              "defmodule Y do\n  @impl true\n  def init(s), do: {:ok, s}\n  defmacro m, do: 1\nend\n"
          }
        )

      assert_specs(exempt)

      hidden_removed =
        Commit.new(
          before: %{
            "lib/z.ex" =>
              "defmodule Z do\n  @doc false\n  def internal, do: 1\n  def api, do: 2\nend\n"
          },
          after: %{"lib/z.ex" => "defmodule Z do\n  def api, do: 2\nend\n"}
        )

      assert_removals_deprecated(hidden_removed)
    end

    test "binary files get no hunks" do
      [change] = Commit.new(after: %{"img.png" => <<137, 80, 78, 71, 0, 1>>}).changes
      assert change.binary?
      assert change.hunks == []
    end
  end

  describe "Query.behaviour_changed?/2" do
    test "is scoped by path, so a migration under priv/ is not a lib/ behaviour change" do
      commit =
        Commit.new(
          after: %{
            "priv/repo/migrations/1_x.exs" => "defmodule X do\n  def change, do: :ok\nend\n"
          }
        )

      assert behaviour_changed?(commit)
      refute behaviour_changed?(commit, ~r{^lib/})
      assert function_changes(commit, ~r{^lib/}) == %{added: [], removed: [], body_changed: []}
      AssertCommit.Assertions.ExUnit.assert_behaviour_changes_tested(commit)
    end
  end

  describe "assert_pure_move/1 under the rename map" do
    @before %{
      "lib/shop/cart.ex" =>
        "defmodule Shop.Cart do\n  def total(items), do: Enum.sum(items)\nend\n",
      "lib/shop/checkout.ex" =>
        "defmodule Shop.Checkout do\n  alias Shop.Cart\n  def run(items), do: Shop.Cart.total(items) + Cart.total([])\nend\n",
      "lib/shop/cart/item.ex" => "defmodule Shop.Cart.Item do\n  defstruct [:price]\nend\n",
      "README.md" => "Use `Shop.Cart.total/1`.\n"
    }

    defp moved(extra \\ %{}) do
      after_files =
        Map.merge(
          %{
            "lib/shop/basket.ex" =>
              "defmodule Shop.Basket do\n  def total(items), do: Enum.sum(items)\nend\n",
            "lib/shop/checkout.ex" =>
              "defmodule Shop.Checkout do\n  alias Shop.Basket\n  def run(items), do: Shop.Basket.total(items) + Basket.total([])\nend\n",
            "lib/shop/cart/item.ex" => "defmodule Shop.Cart.Item do\n  defstruct [:price]\nend\n",
            "README.md" => "Use `Shop.Basket.total/1`.\n"
          },
          extra
        )

      Commit.new(
        before: @before,
        after: after_files,
        renames: [{"lib/shop/cart.ex", "lib/shop/basket.ex"}]
      )
    end

    test "callers, aliases, and docs updated for the new name are part of the move" do
      commit = moved()
      assert modules_renamed(commit) == [{Shop.Cart, Shop.Basket}]
      # Shop.Cart.Item keeps its name: the substitution must not touch deeper modules.
      assert modules_added(commit) == [] and modules_removed(commit) == []
      assert_pure_move(commit)
    end

    test "a behaviour change hidden in the move is reported" do
      commit =
        moved(%{
          "lib/shop/checkout.ex" =>
            "defmodule Shop.Checkout do\n  alias Shop.Basket\n  def run(items), do: Shop.Basket.total(items) + Basket.total([]) + 1\nend\n"
        })

      error = assert_raise AssertCommit.Violation, fn -> assert_pure_move(commit) end
      assert error.message =~ "Shop.Checkout.run/1 (added or changed)"
      assert error.message =~ "Shop.Checkout.run/1 (removed or changed)"
    end

    test "moving a non-Elixir file and updating references to its path is a pure move" do
      before = %{
        "guides/img/a.png" => "png",
        "guides/intro.md" => "See guides/img/a.png and guides/img/a.png.\n"
      }

      after_files = %{"img/a.png" => "png", "guides/intro.md" => "See img/a.png and img/a.png.\n"}

      commit =
        Commit.new(
          before: before,
          after: after_files,
          renames: [{"guides/img/a.png", "img/a.png"}]
        )

      assert modules_renamed(commit) == []
      assert_pure_move(commit)

      edited =
        Commit.new(
          before: before,
          after: Map.put(after_files, "guides/intro.md", "See img/a.png. New prose.\n"),
          renames: [{"guides/img/a.png", "img/a.png"}]
        )

      assert_raise AssertCommit.Violation,
                   ~r/guides\/intro\.md \(modified, not a rename-only change\)/,
                   fn -> assert_pure_move(edited) end
    end

    test "an unrelated file change is reported" do
      commit = moved(%{"README.md" => "Use `Shop.Basket.total/1`. Also new prose.\n"})

      assert_raise AssertCommit.Violation,
                   ~r/README\.md \(modified, not a rename-only change\)/,
                   fn -> assert_pure_move(commit) end
    end
  end

  describe "false positives the adapters must not produce" do
    import AssertCommit.Assertions.{Ecto, OTP, Phoenix}

    @router "lib/demo_web/router.ex"

    test "an action_fallback controller and a router-mentioned controller count as routed" do
      commit =
        Commit.new(
          before: %{
            @router =>
              "defmodule DemoWeb.Router do\n  use Phoenix.Router\n  my_routes DemoWeb.SpecialController\nend\n"
          },
          after: %{
            @router =>
              "defmodule DemoWeb.Router do\n  use Phoenix.Router\n  my_routes DemoWeb.SpecialController\nend\n",
            "lib/demo_web/controllers/fallback_controller.ex" =>
              "defmodule DemoWeb.FallbackController do\n  use DemoWeb, :controller\nend\n",
            "lib/demo_web/controllers/post_controller.ex" =>
              "defmodule DemoWeb.PostController do\n  use DemoWeb, :controller\n  action_fallback DemoWeb.FallbackController\nend\n",
            "lib/demo_web/controllers/special_controller.ex" =>
              "defmodule DemoWeb.SpecialController do\n  use DemoWeb, :controller\nend\n"
          }
        )

      # PostController itself is unrouted; the other two are legitimately so.
      error = assert_raise AssertCommit.Violation, fn -> assert_routed(commit) end
      assert error.message =~ "DemoWeb.PostController (controller)"
      refute error.message =~ "FallbackController"
      refute error.message =~ "SpecialController"
    end

    test "a process started dynamically by another module counts as supervised" do
      commit =
        Commit.new(
          after: %{
            "lib/demo/worker.ex" => "defmodule Demo.Worker do\n  use GenServer\nend\n",
            "lib/demo/pool.ex" =>
              "defmodule Demo.Pool do\n  def start(arg), do: DynamicSupervisor.start_child(Demo.DynSup, {Demo.Worker, arg})\nend\n"
          }
        )

      assert_supervised(commit)

      orphan =
        Commit.new(
          after: %{"lib/demo/worker.ex" => "defmodule Demo.Worker do\n  use GenServer\nend\n"}
        )

      assert_raise AssertCommit.Violation, ~r/Demo\.Worker \(gen_server\)/, fn ->
        assert_supervised(orphan)
      end
    end

    test "virtual fields do not demand a migration" do
      commit =
        Commit.new(
          before: %{
            "lib/demo/user.ex" =>
              "defmodule Demo.User do\n  use Ecto.Schema\n  schema \"users\" do\n  end\nend\n"
          },
          after: %{
            "lib/demo/user.ex" =>
              "defmodule Demo.User do\n  use Ecto.Schema\n  schema \"users\" do\n    field :password, :string, virtual: true\n  end\nend\n"
          }
        )

      assert_schema_changes_migrated(commit)
    end

    test "migrations_immutable since: needs a repository and skips otherwise" do
      commit = Commit.new(after: %{})
      assert {:skip, reason} = assert_migrations_immutable(commit, since: "origin/main")
      assert reason =~ "needs a git-backed change set"
    end
  end

  describe "Commit.restrict/2" do
    test "narrows the changes and the structural diff but keeps the trees whole" do
      commit =
        Commit.new(
          after: %{
            "apps/a/lib/a.ex" => "defmodule A do\n  def f, do: 1\nend\n",
            "apps/b/lib/b.ex" => "defmodule B do\n  def g, do: 1\nend\n"
          }
        )

      scoped = Commit.restrict(commit, ~r{^apps/a/})
      assert Enum.map(scoped.changes, & &1.path) == ["apps/a/lib/a.ex"]
      assert modules_added(scoped) == [A]
      assert AssertCommit.Tree.exists?(scoped.after, "apps/b/lib/b.ex")
      assert modules_added(commit) == [A, B]
    end
  end

  describe "Query.formatting_only?/1" do
    test "true for a whitespace-only edit" do
      assert formatting_only?(Commit.new(before: %{"a" => "x=1\n"}, after: %{"a" => "x = 1\n"}))
    end

    test "false when tokens change or files are added" do
      refute formatting_only?(Commit.new(before: %{"a" => "x=1\n"}, after: %{"a" => "x = 2\n"}))

      refute formatting_only?(
               Commit.new(before: %{"a" => "x=1\n"}, after: %{"a" => "x = 1\n", "b" => "\n"})
             )

      refute formatting_only?(Commit.new(before: %{}, after: %{}))
    end
  end
end
