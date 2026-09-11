defmodule Toolkit.Text do
  @moduledoc "Text utilities."

  @spec words(String.t()) :: [String.t()]
  def words(text), do: String.split(text)
end
