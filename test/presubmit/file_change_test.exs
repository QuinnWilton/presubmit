defmodule Presubmit.FileChangeTest do
  use ExUnit.Case, async: true

  alias Presubmit.{Commit, FileChange, FixtureRepo, Fixtures, Git, Tree}

  test "files over the size cap are not line-diffed" do
    big = String.duplicate("x\n", div(FileChange.max_diff_bytes(), 2) + 1)
    [change] = Commit.new(before: %{"big" => big}, after: %{"big" => big <> "y\n"}).changes
    assert %FileChange{diffed?: false, binary?: false, hunks: [], additions: 0} = change

    [small] = Commit.new(before: %{"s" => "a\n"}, after: %{"s" => "b\n"}).changes
    assert small.diffed?
  end

  test "submodule entries are not listed as files" do
    dir =
      Path.join(System.tmp_dir!(), "presubmit_gitlink_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    inner = FixtureRepo.init!(Path.join(dir, "inner"))
    FixtureRepo.commit!(inner, message: "inner", write: %{"i.txt" => "i\n"})
    outer = FixtureRepo.init!(Path.join(dir, "outer"))

    FixtureRepo.git!(outer.path, [
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "add",
      "-q",
      inner.path,
      "vendor/inner"
    ])

    outer = FixtureRepo.commit!(outer, message: "add submodule", write: %{"a.txt" => "a\n"})

    commit = Commit.head(repo: outer.path)
    paths = Tree.paths(commit.after)
    assert "a.txt" in paths and ".gitmodules" in paths
    refute "vendor/inner" in paths
    assert Enum.map(commit.changes, & &1.path) == [".gitmodules", "a.txt"]
    _ = Fixtures
    _ = Git
  end
end
