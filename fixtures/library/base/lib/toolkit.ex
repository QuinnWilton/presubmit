defmodule Toolkit do
  @moduledoc "Small string helpers."

  @spec greet(String.t()) :: String.t()
  def greet(name), do: "Hello, #{name}!"

  @spec shout(String.t()) :: String.t()
  def shout(text), do: String.upcase(text) <> "!"
end
