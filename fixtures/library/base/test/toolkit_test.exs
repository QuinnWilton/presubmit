defmodule ToolkitTest do
  use ExUnit.Case, async: true

  test "greet/1" do
    assert Toolkit.greet("Ada") == "Hello, Ada!"
  end
end
