defmodule DemoWeb.UserController do
  use DemoWeb, :controller

  def index(conn, _params) do
    render(conn, :index, users: Demo.Accounts.list_users())
  end
end
