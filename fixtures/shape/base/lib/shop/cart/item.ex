defmodule Shop.Cart.Item do
  @moduledoc "A line item."

  defstruct [:price, :quantity]

  @type t :: %__MODULE__{price: non_neg_integer(), quantity: pos_integer()}
end
