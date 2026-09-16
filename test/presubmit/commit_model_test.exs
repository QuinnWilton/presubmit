defmodule Presubmit.CommitModelTest do
  @moduledoc """
  A stateful model of a repository: random sequences of working-tree edits,
  staging, commits, and amends are applied to a real repository and to
  three maps (HEAD's tree, the index, the working tree). Every git-backed
  change-set source must then agree with `Commit.new/1` over the maps.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Presubmit.{Commit, FixtureRepo, Tree}

  @moduletag :tmp_dir

  # A small pool so that sequences collide on paths. No path is a directory of another.
  @paths ~w(a.txt d/b.txt d/e/c.txt f.txt)

  defp op_gen do
    path = member_of(@paths)

    one_of([
      tuple({constant(:write), path}),
      tuple({constant(:delete), path}),
      tuple({constant(:rename), path, path}),
      constant(:stage),
      constant(:commit),
      constant(:amend)
    ])
  end

  property "rev, staged, and worktree agree with Commit.new over the model", %{tmp_dir: dir} do
    check all(ops <- list_of(op_gen(), min_length: 1, max_length: 10), max_runs: 25) do
      repo = FixtureRepo.init!(Path.join(dir, "run#{System.unique_integer([:positive])}"))
      initial = %{"a.txt" => "line 0\n"}
      repo = FixtureRepo.commit!(repo, message: "initial", write: initial)

      model = %{head: initial, parent: nil, index: initial, work: initial, n: 1}
      model = Enum.reduce(ops, model, &apply_op(&1, &2, repo.path))

      assert_same(Commit.staged(repo: repo.path), model.head, model.index)
      assert_same(Commit.worktree(repo: repo.path), model.head, model.work)
      assert_same(Commit.head(repo: repo.path), model.parent || %{}, model.head)

      if model.parent do
        assert_same(Commit.staged(repo: repo.path, base: "HEAD^"), model.parent, model.index)
      end

      File.rm_rf!(repo.path)
    end
  end

  # Contents are unique per write, so git's rename detection can only ever pair identical blobs,
  # which is exactly what the model pairs.
  defp apply_op({:write, path}, model, repo) do
    contents = "line #{model.n}\n"
    write!(repo, path, contents)
    %{model | work: Map.put(model.work, path, contents), n: model.n + 1}
  end

  defp apply_op({:delete, path}, model, repo) do
    if Map.has_key?(model.work, path) do
      File.rm!(Path.join(repo, path))
      %{model | work: Map.delete(model.work, path)}
    else
      model
    end
  end

  defp apply_op({:rename, from, to}, model, repo) do
    if Map.has_key?(model.work, from) and from != to do
      File.mkdir_p!(Path.dirname(Path.join(repo, to)))
      File.rename!(Path.join(repo, from), Path.join(repo, to))
      %{model | work: model.work |> Map.put(to, model.work[from]) |> Map.delete(from)}
    else
      model
    end
  end

  defp apply_op(:stage, model, repo) do
    FixtureRepo.git!(repo, ["add", "-A"])
    %{model | index: model.work}
  end

  defp apply_op(:commit, model, repo) do
    FixtureRepo.git!(repo, ["commit", "-q", "--allow-empty", "--no-verify", "-m", "c#{model.n}"])
    %{model | parent: model.head, head: model.index}
  end

  defp apply_op(:amend, model, repo) do
    FixtureRepo.git!(repo, [
      "commit",
      "-q",
      "--amend",
      "--allow-empty",
      "--no-verify",
      "-m",
      "a#{model.n}"
    ])

    %{model | head: model.index}
  end

  defp write!(repo, path, contents) do
    dest = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, contents)
  end

  defp assert_same(%Commit{} = actual, before, after_files) do
    renames =
      for {old, contents} <- before,
          not Map.has_key?(after_files, old),
          {new, ^contents} <- after_files,
          not Map.has_key?(before, new),
          do: {old, new}

    expected = Commit.new(before: before, after: after_files, renames: renames)

    assert project(actual) == project(expected)
    assert actual.before.paths == MapSet.new(Map.keys(before))
    assert actual.after.paths == MapSet.new(Map.keys(after_files))
    for {path, contents} <- after_files, do: assert(Tree.read!(actual.after, path) == contents)
    for {path, contents} <- before, do: assert(Tree.read!(actual.before, path) == contents)
  end

  defp project(%Commit{changes: changes}) do
    changes
    |> Enum.map(&{&1.status, &1.path, &1.old_path, &1.additions, &1.deletions})
    |> Enum.sort()
  end
end
