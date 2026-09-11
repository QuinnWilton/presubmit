defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  test "total/1 sums price times quantity" do
    cart = %Shop.Cart{items: [%Shop.Cart.Item{price: 3, quantity: 2}]}
    assert Shop.Cart.total(cart) == 6
  end
end
