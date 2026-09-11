defmodule AssertCommit.Fixtures do
  @moduledoc """
  Builds the fixture repositories under `fixtures/` for integration tests.

  A fixture family is a directory with a `base/` tree and a `scenarios/`
  directory of `git format-patch` files. `build!/2` initialises a repository
  from the base tree, commits it on `main`, and applies each patch on its own
  `scenario/<name>` branch, so a test can pin the diff it is about with
  `rev: "scenario/<name>"`.

  Patches are the readable source of truth for what each scenario changes;
  regenerate one by checking out the base, making the change, and running
  `git format-patch -1 -k -M --binary --no-signature` (`-k` keeps the subject
  verbatim, so `[component]` prefixes survive `git am -k`).
  """

  alias AssertCommit.FixtureRepo

  @root Path.expand("../../fixtures", __DIR__)

  @doc "Names of every scenario in `family`, from its patch files."
  @spec scenarios(String.t()) :: [atom()]
  def scenarios(family) do
    [@root, family, "scenarios", "*.patch"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename(".patch") |> String.to_atom()))
    |> Enum.sort()
  end

  @doc """
  Builds the `family` fixture in a fresh directory under `tmp/` for a
  `setup_all`, removing it when the module's tests finish.

      setup_all do: %{repo: Fixtures.repo("phoenix")}
  """
  @spec repo(String.t()) :: Path.t()
  def repo(family) do
    dir =
      Path.expand("../../tmp/fixtures/#{family}-#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    build!(family, dir)
  end

  @doc """
  Builds the `family` fixture under `dir` and returns the repository path.

  `main` holds the base commit; each scenario is one commit on `scenario/<name>`.
  """
  @spec build!(String.t(), Path.t()) :: Path.t()
  def build!(family, dir) do
    family_dir = Path.join(@root, family)
    base = Path.join(family_dir, "base")

    unless File.dir?(base) do
      raise ArgumentError, "no fixture family #{inspect(family)} at #{family_dir}"
    end

    repo = FixtureRepo.init!(dir)
    File.cp_r!(base, repo.path)
    repo = FixtureRepo.commit!(repo, message: "Base")

    for scenario <- scenarios(family) do
      patch = Path.join([family_dir, "scenarios", "#{scenario}.patch"])
      FixtureRepo.git!(repo.path, ["checkout", "-q", "-b", "scenario/#{scenario}", "main"])

      FixtureRepo.git!(repo.path, ["am", "-3", "-k", "-q", patch],
        env: [{"GIT_COMMITTER_DATE", "2026-01-02T00:00:00Z"}]
      )
    end

    FixtureRepo.git!(repo.path, ["checkout", "-q", "main"])
    repo.path
  end
end
