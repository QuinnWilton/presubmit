defmodule AssertCommit.Assertions.Flunk do
  @moduledoc false

  @doc "Raises `ExUnit.AssertionError` with a string or a list of lines."
  @spec flunk(String.t() | [String.t() | [String.t()]]) :: no_return()
  def flunk(lines) when is_list(lines), do: lines |> List.flatten() |> Enum.join("\n") |> flunk()
  def flunk(message) when is_binary(message), do: raise(ExUnit.AssertionError, message: message)

  @spec indent([String.t()]) :: [String.t()]
  def indent(items), do: Enum.map(items, &("  " <> &1))
end
