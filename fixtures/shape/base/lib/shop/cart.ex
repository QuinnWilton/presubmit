defmodule Shop.Cart do
  @moduledoc "A shopping cart."

  defstruct items: []

  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{items: items}) do
    Enum.reduce(items, 0, fn item, acc -> acc + item.price * item.quantity end)
  end

  @type t :: %__MODULE__{items: [Shop.Cart.Item.t()]}
end
