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

  test "--message-file attaches a message to the staged change set, as a commit-msg hook would",
       %{repo: repo} do
    File.write!(
      Path.join(repo, "lib/demo/hooked.ex"),
      "defmodule Demo.Hooked do\n  @moduledoc false\n  @spec x() :: 1\n  def x, do: 1\nend\n"
    )

    on_exit(fn ->
      AssertCommit.Git.run!(repo, ["reset", "-q", "--", "lib/demo/hooked.ex"]) &&
        File.rm(Path.join(repo, "lib/demo/hooked.ex"))
    end)

    AssertCommit.Git.run!(repo, ["add", "lib/demo/hooked.ex"])

    message =
      Path.join(System.tmp_dir!(), "assert_commit_msg_#{System.unique_integer([:positive])}")

    File.write!(message, "fixup! wip\n\n# Please enter the commit message\n")
    on_exit(fn -> File.rm(message) end)

    {1, out} = run(["--repo", repo, "--staged", "--message-file", message, "--no-color"])
    assert out =~ ~r/^Examining staged index \(1 file differs from HEAD\) — fixup! wip\n/m
    assert out =~ "✗ no fixup!/squash!/amend! commits"
    refute out =~ "skipped: needs a commit message"

    {0, out} =
      run([
        "--repo",
        repo,
        "--staged",
        "--message",
        "Add hooked",
        "--no-color",
        "--config",
        write_config(repo, "[AssertCommit.Rules.Message]")
      ])

    assert out =~ "— Add hooked\n"
    assert out =~ "✓ no fixup!/squash!/amend! commits"
  end

  test "--base checks the amended commit rather than the delta since HEAD" do
    # scenario/lib_with_tests: one commit that changes lib/ and its test together.
    repo = AssertCommit.Fixtures.repo("shape")
    AssertCommit.Git.run!(repo, ["checkout", "-q", "scenario/lib_with_tests"])
    cart = Path.join(repo, "lib/shop/cart.ex")

    File.write!(
      cart,
      String.replace(
        File.read!(cart),
        "ceil(item.price * item.quantity)",
        "ceil(item.price * item.quantity * 1)"
      )
    )

    AssertCommit.Git.run!(repo, ["add", "lib/shop/cart.ex"])

    config =
      write_config(repo, "[{AssertCommit.Rules.ExUnit, only: [:behaviour_changes_tested]}]")

    # The delta alone changes lib/ without touching a test: an amendment could never satisfy this.
    {1, delta} = run(["--repo", repo, "--staged", "--no-color", "--config", config])
    assert delta =~ "✗ behaviour changes in lib/ come with test changes"

    # Measured against HEAD^, the change set is the commit the amend will produce, test included.
    {0, amended} =
      run(["--repo", repo, "--staged", "--base", "HEAD^", "--no-color", "--config", config])

    assert amended =~ ~r/^Examining staged index \(2 files differ from HEAD\^\)\n/m
    assert amended =~ "✓ behaviour changes in lib/ come with test changes"
  end

  test "a message cannot be attached to a commit, and only one message option is accepted", %{
    repo: repo
  } do
    assert {2, "error: --message only applies to --staged or --worktree" <> _} =
             run(["--repo", repo, "--head", "--message", "x"])

    assert {2, "error: pass either --message or --message-file" <> _} =
             run(["--repo", repo, "--staged", "--message", "x", "--message-file", "y"])

    assert {2, "error: cannot read --message-file /nope: " <> _} =
             run(["--repo", repo, "--staged", "--message-file", "/nope"])

    assert {2, "error: --base only applies to --staged or --worktree" <> _} =
             run(["--repo", repo, "--head", "--base", "HEAD^"])
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

  test "--on-error decides whether a crashed rule fails the run", %{repo: repo} do
    config =
      write_config(repo, """
      unless Code.ensure_loaded?(CLITestCrash) do
        defmodule CLITestCrash do
          use AssertCommit.RuleSet
          rule :boom, "boom", fn _ -> raise "kaboom" end
        end
      end

      [CLITestCrash]
      """)

    {1, out} = run(["--repo", repo, "--head", "--no-color", "--config", config])
    assert out =~ "! boom raised RuntimeError"
    assert out =~ "1 rule: 1 errored"

    {0, out} =
      run(["--repo", repo, "--head", "--no-color", "--config", config, "--on-error", "warn"])

    assert out =~ "! boom raised RuntimeError"

    assert {2, "error: unknown --on-error maybe" <> _} =
             run(["--repo", repo, "--head", "--on-error", "maybe"])
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
