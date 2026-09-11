defmodule AssertCommit.ChangelogTest do
  use ExUnit.Case, async: true

  alias AssertCommit.{Changelog, Tree}

  @text """
  # Changelog

  ## [Unreleased]

  - Something new.

  ## [1.2.0] - 2026-01-01

  ### Added
  - X.

  ## v1.1.0 — 2025-12-01

  - Y.

  ## 1.0.0
  """

  test "sections with lenient version headings" do
    sections = Changelog.parse(@text)

    assert Enum.map(sections, &{&1.heading, &1.version}) == [
             {"[Unreleased]", nil},
             {"[1.2.0] - 2026-01-01", "1.2.0"},
             {"v1.1.0 — 2025-12-01", "1.1.0"},
             {"1.0.0", "1.0.0"}
           ]

    assert Enum.at(sections, 1).body == "### Added\n- X."
  end

  test "unreleased and section_for" do
    tree = Tree.from_map(%{"CHANGELOG.md" => @text})
    assert Changelog.unreleased(tree).body == "- Something new."
    assert Changelog.section_for(tree, "1.1.0").body == "- Y."
    assert Changelog.section_for(tree, "9.9.9") == nil
    assert Changelog.unreleased(Tree.from_map(%{})) == nil
  end
end
