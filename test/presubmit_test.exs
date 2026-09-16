defmodule PresubmitTest do
  use ExUnit.Case, async: true

  alias Presubmit.{Commit, Fixtures}

  setup_all do: %{repo: Fixtures.repo("shape")}

  describe "load/1 with source: :auto" do
    test "resolves to :head when clean and :worktree when dirty", %{repo: repo} do
      assert Presubmit.resolve_source(repo: repo, source: :auto) == :head
      assert %Commit{source: :head} = Presubmit.load(repo: repo, source: :auto)

      File.write!(Path.join(repo, "note.md"), "scratch\n")
      on_exit(fn -> File.rm(Path.join(repo, "note.md")) end)
      assert Presubmit.resolve_source(repo: repo, source: :auto) == :worktree

      assert %Commit{source: :worktree, changes: [%{path: "note.md"}]} =
               Presubmit.load(repo: repo, source: :auto)
    end

    test "message: attaches a cleaned message to a message-less change set", %{repo: repo} do
      commit = Presubmit.load(repo: repo, source: :staged, message: "[x] hi\n# comment\n")
      assert commit.message.subject == "[x] hi"
      assert Presubmit.load(repo: repo, source: :staged).message == nil
    end

    test "explicit sources pass through" do
      assert Presubmit.resolve_source(source: :staged) == :staged
      assert Presubmit.resolve_source(source: {:rev, "abc"}) == {:rev, "abc"}
    end
  end
end
