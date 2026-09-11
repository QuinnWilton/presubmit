defmodule DemoWeb.UserControllerTest do
  use DemoWeb.ConnCase, async: true

  test "index", %{conn: conn} do
    assert html_response(get(conn, "/"), 200)
  end
end
