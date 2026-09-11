defmodule DemoWeb.Router do
  use DemoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
  end

  scope "/", DemoWeb do
    pipe_through :browser

    get "/users", UserController, :index
  end
end
