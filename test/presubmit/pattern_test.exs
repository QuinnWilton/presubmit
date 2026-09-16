defmodule Presubmit.PatternTest do
  use ExUnit.Case, async: true

  alias Presubmit.Pattern

  test "nil matches everything" do
    assert Pattern.matches?("anything", nil)
  end

  test "strings match exactly" do
    assert Pattern.matches?("mix.exs", "mix.exs")
    refute Pattern.matches?("sub/mix.exs", "mix.exs")
  end

  test "regexes and lists" do
    assert Pattern.matches?("lib/a.ex", ~r{^lib/})
    assert Pattern.matches?("mix.lock", ["mix.exs", "mix.lock"])
    refute Pattern.matches?("README.md", [~r{^lib/}, "mix.exs"])
  end

  test "format/1 is readable in failure messages" do
    assert Pattern.format(["mix.exs", ~r{^lib/}]) == ~s|"mix.exs" or ~r/^lib\\//|
    assert Pattern.format(nil) == "any path"
  end
end
