defmodule AssertCommit.Changelog do
  @moduledoc """
  Reads a Markdown changelog as a list of sections keyed by heading.

  Any `##` heading starts a section. Version headings are matched
  leniently: `## 1.2.0`, `## v1.2.0`, `## [1.2.0]`, and `## 1.2.0 - 2026-01-01`
  all name version `1.2.0`. The unreleased section is any heading that
  contains "unreleased" case-insensitively.
  """

  alias AssertCommit.Tree

  @type section :: %{heading: String.t(), version: String.t() | nil, body: String.t()}

  @doc "Sections of the changelog at `path`, or `[]` if absent."
  @spec sections(Tree.t(), String.t()) :: [section()]
  def sections(%Tree{} = tree, path \\ "CHANGELOG.md") do
    case Tree.read(tree, path) do
      {:ok, text} -> parse(text)
      :error -> []
    end
  end

  @doc "Parses changelog text into sections."
  @spec parse(String.t()) :: [section()]
  def parse(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case Regex.run(~r/^##\s+(.+?)\s*$/, line) do
        [_, heading] ->
          [%{heading: heading, version: version(heading), body: ""} | acc]

        nil ->
          case acc do
            [section | rest] -> [%{section | body: section.body <> line <> "\n"} | rest]
            [] -> []
          end
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&%{&1 | body: String.trim(&1.body)})
  end

  @doc "The unreleased section, if any."
  @spec unreleased(Tree.t(), String.t()) :: section() | nil
  def unreleased(tree, path \\ "CHANGELOG.md") do
    tree |> sections(path) |> Enum.find(&(&1.heading =~ ~r/unreleased/i))
  end

  @doc "The section for `version`, if any."
  @spec section_for(Tree.t(), String.t(), String.t()) :: section() | nil
  def section_for(tree, version, path \\ "CHANGELOG.md") do
    tree |> sections(path) |> Enum.find(&(&1.version == version))
  end

  defp version(heading) do
    case Regex.run(~r/^\[?v?(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\]?/, heading) do
      [_, version] -> version
      nil -> nil
    end
  end
end
