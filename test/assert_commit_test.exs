defmodule AssertCommitTest.StaticPolicy do
  @moduledoc """
  `use AssertCommit` with static options loads the commit once in `setup_all`.

  Tags are merged over the `setup_all` context, so the injected `commit` key
  must survive a module with tags of its own (and the tag `use AssertCommit`
  adds must not be `:commit`).
  """

  use ExUnit.Case, async: true

  @dir Path.expand("../tmp/fixtures/static-policy", __DIR__)

  setup_all do
    File.rm_rf!(@dir)
    File.mkdir_p!(@dir)
    on_exit(fn -> File.rm_rf!(@dir) end)
    AssertCommit.Fixtures.build!("shape", @dir)
    :ok
  end

  use AssertCommit, repo: Path.join(@dir, "repo"), rev: "scenario/pure_move"

  @moduletag :static_policy

  test "the loaded commit survives tag merging", %{commit: commit} = context do
    assert %AssertCommit.Commit{source: :rev} = commit
    assert commit.message.subject =~ "Move"
    assert context.assert_commit == true
    assert context.static_policy == true
  end
end

defmodule AssertCommitTest do
  use ExUnit.Case, async: true

  alias AssertCommit.{Commit, Fixtures}

  setup_all do: %{repo: Fixtures.repo("shape")}

  test "function options are resolved against the test context", %{repo: repo} do
    opts = [repo: & &1.repo, rev: &"scenario/#{&1.scenario}"]

    assert AssertCommit.commit(opts, %{repo: repo, scenario: :docs_only}).message.subject =~
             "Document"

    assert AssertCommit.commit(opts, %{repo: repo, scenario: :oversized}).message.subject =~
             "Generate"
  end

  test "source: :staged loads the index", %{repo: repo} do
    assert %Commit{source: :staged, message: nil} =
             AssertCommit.commit(repo: repo, source: :staged)
  end
end
