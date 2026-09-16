defmodule Presubmit.Paths do
  @moduledoc """
  Path patterns for the conventional directories, anchored so they work at
  the repository root and inside umbrella apps or subdirectory projects
  (`apps/foo/lib/`, `services/bar/test/`).
  """

  @doc "Library source: `lib/` at the root or under any directory."
  @spec lib() :: Regex.t()
  def lib, do: ~r{(^|/)lib/}

  @doc "Tests: `test/` at the root or under any directory."
  @spec test() :: Regex.t()
  def test, do: ~r{(^|/)test/}

  @doc "Elixir source files under `lib/`, `priv/`, or `test/` anywhere."
  @spec elixir_source() :: Regex.t()
  def elixir_source, do: ~r{(^|/)(lib|priv|test)/.*\.exs?$}

  @doc "Migration files under any `migrations/` directory."
  @spec migrations() :: Regex.t()
  def migrations, do: ~r{/migrations/.*\.exs$}

  @doc "Every `mix.exs` in the tree, excluding vendored dependencies."
  @spec mix_files() :: Regex.t()
  def mix_files, do: ~r{(^|/)mix\.exs$}

  @doc "Every `mix.lock` in the tree, excluding vendored dependencies."
  @spec lock_files() :: Regex.t()
  def lock_files, do: ~r{(^|/)mix\.lock$}

  @doc "Vendored dependency directories, which are never part of the project."
  @spec vendored?(String.t()) :: boolean()
  def vendored?(path), do: Regex.match?(~r{(^|/)(deps|_build|node_modules)/}, path)
end
