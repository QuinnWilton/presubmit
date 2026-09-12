defmodule AssertCommit.CLITest do
  use ExUnit.Case, async: true

  alias AssertCommit.{CLI, Fixtures}

  setup_all do: %{repo: Fixtures.repo("phoenix")}

  defp run(args, env \\ [ci: false]) do
    {status, output} = CLI.main(args, env)
    {status, IO.iodata_to_binary(output)}
  end

  test "without a config file, the defaults are announced with their detection", %{repo: repo} do
    {1, out} = run(["--repo", repo, "--rev", "scenario/unrouted_controller", "--no-color"])
    assert out =~ "No .assert_commit.exs; using built-in defaults.\n"

    assert out =~
             ~r/^  enabled: Elixir, Phoenix \(phoenix is a dependency\), Ecto \(ecto_sql is a dependency\), OTP, ExUnit, Mix, Message, Hygiene, Shape\n/m

    assert out =~ ~r/^  not enabled: Changelog \(no CHANGELOG\.md\)\n/m
    refute out =~ "public API changes are recorded"
    refute out =~ "added modules have a test module"
  end

  test "--rev examines a commit and exits 1 on failures", %{repo: repo} do
    {1, out} = run(["--repo", repo, "--rev", "scenario/unrouted_controller", "--no-color"])
    assert out =~ ~r/^Examining [0-9a-f]{7} Add posts index\n/m
    assert out =~ "✗ added controllers and LiveViews are routed"
    assert out =~ ~r/\d+ rules: \d+ passed, \d+ failed/
  end

  test "--rev exits 0 when everything passes or is skipped", %{repo: repo} do
    {0, out} =
      run([
        "--repo",
        repo,
        "--rev",
        "scenario/migration_newest",
        "--no-color",
        "--config",
        write_config(repo, "[{AssertCommit.Rules.Ecto, []}]")
      ])

    refute out =~ "✗"
  end

  test "auto picks HEAD on a clean tree and the working tree on a dirty one", %{repo: repo} do
    {_, clean} = run(["--repo", repo, "--no-color"])
    assert clean =~ ~r/^Examining [0-9a-f]{7} Base\n/m

    File.write!(
      Path.join(repo, "lib/demo/scratch.ex"),
      "defmodule Demo.Scratch do\n  def x, do: IO.inspect(1)\nend\n"
    )

    on_exit(fn -> File.rm(Path.join(repo, "lib/demo/scratch.ex")) end)

    {1, dirty} = run(["--repo", repo, "--no-color"])
    assert dirty =~ ~r/^Examining working tree \(1 file differs from HEAD\)\n/m
    assert dirty =~ "lib/demo/scratch.ex:2: def x, do: IO.inspect(1)"
    assert dirty =~ "(skipped: needs a commit message; the change set was built from :worktree)"
    refute dirty =~ "warning:"

    {1, ci} = run(["--repo", repo, "--no-color"], ci: true)
    assert ci =~ ~r/^warning: the working tree differs from HEAD in 1 file\(s\) and CI is set/
    assert ci =~ "Pass --rev HEAD (or --head) to gate the commit itself."

    {_, head} = run(["--repo", repo, "--head", "--no-color"], ci: true)
    refute head =~ "warning:"
    assert head =~ ~r/^Examining [0-9a-f]{7} Base\n/m

    assert AssertCommit.Git.run!(repo, ["diff", "--cached", "--name-only"]) == ""
  end

  test "--range reports every commit in the range", %{repo: repo} do
    {1, out} = run(["--repo", repo, "--range", "main..scenario/migration_rebased", "--no-color"])
    assert out =~ ~r/^Examining [0-9a-f]{7} Create posts\n/m
    assert out =~ "older than the newest existing migration"
  end

  test "--format json", %{repo: repo} do
    {1, out} = run(["--repo", repo, "--rev", "scenario/unrouted_controller", "--format", "json"])

    assert out =~
             ~s|{"config":{"defaults":true,"detection":[{"reasons":[],"set":"AssertCommit.Rules.Elixir","status":"enabled"}|

    assert out =~
             ~s|{"reasons":["phoenix is a dependency"],"set":"AssertCommit.Rules.Phoenix","status":"enabled"}|

    assert out =~ ~s|"id":"routed"|
  end

  test "--list prints the configured sets and rules", %{repo: repo} do
    {0, out} =
      run([
        "--repo",
        repo,
        "--list",
        "--config",
        write_config(repo, "[{AssertCommit.Rules.Ecto, except: [:migrations_reversible]}]")
      ])

    assert out =~
             "AssertCommit.Rules.Ecto [except: [:migrations_reversible]]\n  migrations_ordered — added migrations are newer than every existing one"

    refute out =~ "migrations_reversible — "
  end

  test "usage and configuration errors exit 2", %{repo: repo} do
    assert {2, "error: unknown arguments: --bogus" <> _} = run(["--bogus"])

    assert {2, "error: choose one of --staged, --head\n"} =
             run(["--repo", repo, "--staged", "--head"])

    assert {2, "error: configuration file " <> _} =
             run(["--repo", repo, "--config", "missing.exs"])

    assert {2, "error: unknown --format yaml" <> _} = run(["--repo", repo, "--format", "yaml"])
    assert {2, "error: git log -1" <> _} = run(["--repo", repo, "--rev", "nope"])
  end

  defp write_config(repo, contents) do
    path =
      Path.join(System.tmp_dir!(), "assert_commit_cfg_#{System.unique_integer([:positive])}.exs")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    _ = repo
    path
  end
end
