defmodule AssertCommit.AdaptersTest do
  use ExUnit.Case, async: true

  alias AssertCommit.Adapter

  alias AssertCommit.Adapters.{
    EctoMigration,
    EctoSchema,
    ExUnitCase,
    OtpProcess,
    PhoenixHandler,
    PhoenixRouter
  }

  alias AssertCommit.Source.Facts

  defp module!(source) do
    {:ok, %Facts{modules: modules}} = Facts.from_source(source, "lib/x.ex")
    List.last(modules)
  end

  describe "PhoenixRouter" do
    # Phoenix concatenates every enclosing scope alias onto the plug, so a module-level
    # `alias DemoWeb.Admin` would make `scope "/admin", Admin` resolve to DemoWeb.DemoWeb.Admin.
    # The adapter reproduces that; routers are written without such aliases for this reason.
    test "resolves plugs through nested scopes, live_session, forward, and resources" do
      router =
        module!("""
        defmodule DemoWeb.Router do
          use DemoWeb, :router

          scope "/", DemoWeb do
            get "/", PageController, :home
            live "/posts", PostLive, :index

            scope "/admin", Admin do
              resources "/users", UserController, only: [:index, :show]
            end

            scope "/api", alias: false do
              forward "/graphql", Absinthe.Plug
            end
          end

          scope "/ops", DemoWeb.Ops, as: :ops do
            live_session :default do
              live "/", DashboardLive
            end
          end
        end
        """)

      assert PhoenixRouter.recognize?(router)
      routes = PhoenixRouter.extract(router).routes

      assert Enum.map(routes, &{&1.kind, &1.verb, &1.path, &1.plug, &1.action}) == [
               {:match, :get, "/", DemoWeb.PageController, :home},
               {:live, :get, "/posts", DemoWeb.PostLive, :index},
               {:resources, :get, "/admin/users", DemoWeb.Admin.UserController, :index},
               {:resources, :get, "/admin/users", DemoWeb.Admin.UserController, :show},
               {:forward, :*, "/api/graphql", Absinthe.Plug, nil},
               {:live, :get, "/ops", DemoWeb.Ops.DashboardLive, nil}
             ]

      assert PhoenixRouter.routes?(PhoenixRouter.extract(router), DemoWeb.Admin.UserController)
    end

    test "recognises use Phoenix.Router directly" do
      assert PhoenixRouter.recognize?(module!("defmodule R do\n  use Phoenix.Router\nend\n"))
      refute PhoenixRouter.recognize?(module!("defmodule R do\n  use Phoenix.Controller\nend\n"))
    end
  end

  describe "PhoenixHandler" do
    test "classifies controllers, LiveViews, components, and channels" do
      for {source, kind} <- [
            {"use DemoWeb, :controller", :controller},
            {"use Phoenix.Controller, formats: [:html]", :controller},
            {"use DemoWeb, :live_view", :live_view},
            {"use Phoenix.LiveComponent", :live_component},
            {"use DemoWeb, :channel", :channel}
          ] do
        assert %PhoenixHandler{kind: ^kind} =
                 Adapter.model(PhoenixHandler, module!("defmodule H do\n  #{source}\nend\n"))
      end

      assert PhoenixHandler.routable?(%PhoenixHandler{module: H, kind: :controller})
      refute PhoenixHandler.routable?(%PhoenixHandler{module: H, kind: :channel})

      assert Adapter.model(
               PhoenixHandler,
               module!("defmodule H do\n  use DemoWeb, :router\nend\n")
             ) == nil
    end
  end

  describe "EctoSchema" do
    test "fields, associations, embeds, timestamps, and expected columns" do
      schema =
        module!("""
        defmodule Demo.Post do
          use Ecto.Schema
          alias Demo.Accounts

          schema "posts" do
            field :title, :string
            field :tags, {:array, :string}, default: []
            field :body
            belongs_to :author, Accounts.User
            belongs_to :editor, Accounts.User, foreign_key: :editor_key
            has_many :comments, Demo.Comment
            embeds_one :meta, Demo.Meta
            timestamps()
          end
        end
        """)
        |> then(&Adapter.model(EctoSchema, &1))

      assert schema.source == "posts" and schema.timestamps?

      assert Enum.map(schema.fields, &{&1.name, &1.kind, &1.type || &1.related}) == [
               {:title, :field, :string},
               {:tags, :field, {:array, :string}},
               {:body, :field, :string},
               {:author, :belongs_to, Demo.Accounts.User},
               {:editor, :belongs_to, Demo.Accounts.User},
               {:comments, :has_many, Demo.Comment},
               {:meta, :embeds_one, Demo.Meta}
             ]

      assert EctoSchema.columns(schema) == [:title, :tags, :body, :author_id, :editor_key]
    end

    test "embedded schemas have no source" do
      assert %EctoSchema{source: nil, fields: [%{name: :x}]} =
               Adapter.model(
                 EctoSchema,
                 module!(
                   "defmodule E do\n  use Ecto.Schema\n  embedded_schema do\n    field :x, :integer\n  end\nend\n"
                 )
               )
    end
  end

  describe "EctoMigration" do
    test "operations, version, reversibility, and columns added" do
      m =
        module!("""
        defmodule Demo.Repo.Migrations.Big do
          use Ecto.Migration
          @disable_ddl_transaction true

          def up do
            create table(:posts) do
              add :title, :string, null: false
              add :body, :text
            end

            alter table(:users) do
              add :name, :string
              remove :legacy
              modify :email, :citext
            end

            create index(:posts, [:title], concurrently: true)
            create unique_index(:users, [:email])
            execute "UPDATE users SET name = ''"
          end

          def down do
            drop table(:posts)
            drop index(:posts, [:title])
          end
        end
        """)
        |> Map.put(:path, "priv/repo/migrations/20260301120000_big.exs")
        |> then(&Adapter.model(EctoMigration, &1))

      assert m.version == "20260301120000"
      assert m.functions == [:up, :down]
      assert m.disable_ddl_transaction? and not m.disable_migration_lock?

      assert m.ops == [
               up:
                 {:create_table, :posts,
                  [
                    %{name: :title, type: :string, opts: [null: false]},
                    %{name: :body, type: :text, opts: []}
                  ]},
               up:
                 {:alter_table, :users,
                  [{:add, :name, :string, []}, {:remove, :legacy}, {:modify, :email, :citext, []}]},
               up: {:create_index, :posts, [:title], [concurrently: true]},
               up: {:create_index, :users, [:email], [unique: true]},
               up: {:execute, :irreversible},
               down: {:drop_table, :posts},
               down: {:drop_index, :posts, []}
             ]

      assert EctoMigration.reversible?(m)
      assert EctoMigration.columns_added(m, :posts) == [:title, :body]
      assert EctoMigration.columns_added(m, "users") == [:name]
    end

    test "change/0 with raw execute/1 is irreversible; execute/2 is fine" do
      irreversible =
        Adapter.model(
          EctoMigration,
          module!(
            "defmodule M do\n  use Ecto.Migration\n  def change do\n    execute \"x\"\n  end\nend\n"
          )
        )

      reversible =
        Adapter.model(
          EctoMigration,
          module!(
            ~s|defmodule M do\n  use Ecto.Migration\n  def change do\n    execute "up", "down"\n  end\nend\n|
          )
        )

      refute EctoMigration.reversible?(irreversible)
      assert EctoMigration.reversible?(reversible)
    end
  end

  describe "OtpProcess" do
    test "kinds and child specs in every conventional shape" do
      app =
        module!("""
        defmodule Demo.Application do
          use Application
          alias Demo.Workers

          def start(_, _) do
            children = [
              Demo.Repo,
              {Workers.Cache, []},
              {Registry, keys: :unique, name: Demo.Registry},
              %{id: :x, start: {Demo.Custom, :start_link, []}},
              Demo.Pool.child_spec(size: 2)
            ]

            Supervisor.start_link(children, strategy: :one_for_one)
          end
        end
        """)
        |> then(&Adapter.model(OtpProcess, &1))

      assert app.kind == :application
      assert app.children == [Demo.Repo, Demo.Workers.Cache, Registry, Demo.Custom, Demo.Pool]

      assert %OtpProcess{kind: :gen_server, children: []} =
               Adapter.model(OtpProcess, module!("defmodule S do\n  use GenServer\nend\n"))

      assert %OtpProcess{kind: :gen_server} =
               Adapter.model(OtpProcess, module!("defmodule S do\n  @behaviour GenServer\nend\n"))

      sup =
        Adapter.model(
          OtpProcess,
          module!(
            "defmodule S do\n  use Supervisor\n  def init(_), do: Supervisor.init([A, B], strategy: :one_for_one)\nend\n"
          )
        )

      assert sup.children == [A, B]
      assert OtpProcess.worker?(sup) and not OtpProcess.worker?(app)
    end
  end

  describe "ExUnitCase" do
    test "subject from name, tests, and references" do
      t =
        Adapter.model(
          ExUnitCase,
          module!(
            ~s|defmodule Demo.Accounts.UserTest do\n  use Demo.DataCase, async: true\n  test "a", do: assert Demo.Accounts.create()\n  property "b", do: :ok\nend\n|
          )
        )

      assert t.subject == Demo.Accounts.User
      assert t.tests == ["a", "b"]
      assert ExUnitCase.covers?(t, Demo.Accounts.User)
      assert ExUnitCase.covers?(t, Demo.Accounts)
      refute ExUnitCase.covers?(t, Demo.Other)
      assert Adapter.model(ExUnitCase, module!("defmodule X do\n  use GenServer\nend\n")) == nil
    end
  end
end
