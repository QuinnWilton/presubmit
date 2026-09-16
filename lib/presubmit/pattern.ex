defmodule Presubmit.Pattern do
  @moduledoc """
  Path patterns accepted by every query and assertion.

  A pattern is a `Regex` matched against the repository-relative path, a
  string for an exact path, or a list of either (matching if any element
  matches). `nil` matches everything.
  """

  @type t :: Regex.t() | String.t() | [Regex.t() | String.t()] | nil

  @spec matches?(String.t(), t()) :: boolean()
  def matches?(_path, nil), do: true
  def matches?(path, %Regex{} = regex), do: Regex.match?(regex, path)
  def matches?(path, exact) when is_binary(exact), do: path == exact

  def matches?(path, patterns) when is_list(patterns),
    do: Enum.any?(patterns, &matches?(path, &1))

  @doc """
  Renders a pattern for use in assertion messages.
  """
  @spec format(t()) :: String.t()
  def format(nil), do: "any path"
  def format(%Regex{} = regex), do: inspect(regex)
  def format(exact) when is_binary(exact), do: inspect(exact)
  def format(patterns) when is_list(patterns), do: Enum.map_join(patterns, " or ", &format/1)
end
