defmodule AssertCommit.Assertions.Changelog do
  @moduledoc """
  Assertions over `CHANGELOG.md`, built on `AssertCommit.Changelog`.
  """

  alias AssertCommit.Assertions.Flunk
  alias AssertCommit.{Changelog, Commit, Query}

  @doc """
  Asserts that when the commit changes the public API, the changelog's
  unreleased section gains content.
  """
  @spec assert_api_changes_logged(Commit.t(), String.t()) :: :ok
  def assert_api_changes_logged(%Commit{} = commit, path \\ "CHANGELOG.md") do
    if Query.public_api_changed?(commit) do
      before = Changelog.unreleased(commit.before, path)
      after_section = Changelog.unreleased(commit.after, path)
      %{added: added, removed: removed} = Query.public_api_diff(commit)

      changes =
        Enum.map(added, &"#{format(&1)} added") ++ Enum.map(removed, &"#{format(&1)} removed")

      cond do
        is_nil(after_section) ->
          Flunk.flunk([
            "The public API changed but #{path} has no unreleased section:"
            | Flunk.indent(changes)
          ])

        before != nil and after_section.body == before.body ->
          Flunk.flunk([
            "The public API changed but the unreleased section of #{path} did not:"
            | Flunk.indent(changes)
          ])

        true ->
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Asserts that when the commit bumps the version in `mix.exs`, the changelog
  has a section for the new version.
  """
  @spec assert_release_logged(Commit.t(), String.t()) :: :ok
  def assert_release_logged(%Commit{} = commit, path \\ "CHANGELOG.md") do
    case AssertCommit.Assertions.Mix.version_bump(commit) do
      nil ->
        :ok

      {_old, new} ->
        if Changelog.section_for(commit.after, new, path),
          do: :ok,
          else:
            Flunk.flunk(
              "mix.exs now says version #{new}, but #{path} has no `## #{new}` section."
            )
    end
  end

  defp format({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
end
