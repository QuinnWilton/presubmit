defmodule Presubmit.RunnerTest do
  use ExUnit.Case, async: true

  alias Presubmit.{Commit, Fixtures, Formatter, Rule, Rules, Runner}
  alias Presubmit.Runner.Report

  setup_all do: %{repo: Fixtures.repo("shape")}

  defp rules do
    [
      Rule.new(:ok, "passes", fn _ -> :ok end),
      Rule.new(:soft, "warns", fn _ -> raise Presubmit.Violation, message: "meh" end,
        severity: :warn
      ),
      Rule.new(:bad, "fails", fn _ ->
        raise Presubmit.Violation, message: "line one\n\nline three"
      end),
      Rule.new(:skip, "skips", fn _ -> {:skip, "not configured"} end)
    ]
  end

  test "run/2 collects outcomes and status" do
    report = Runner.run(Commit.new(after: %{}), rules())

    assert Enum.map(report.results, &{&1.rule.id, &1.outcome}) == [
             {:ok, :pass},
             {:soft, {:warn, "meh"}},
             {:bad, {:fail, "line one\n\nline three"}},
             {:skip, {:skip, "not configured"}}
           ]

    assert Report.status(report) == :fail
    assert Report.warnings?(report)
    assert Report.counts(report) == %{pass: 1, fail: 1, warn: 1, skip: 1, error: 0}
    assert Report.status(Runner.run(Commit.new(after: %{}), [hd(rules())])) == :pass
  end

  test "a crashing rule is an error, not a crash", %{repo: _} do
    report =
      Runner.run(Commit.new(after: %{}), [Rule.new(:boom, "boom", fn _ -> raise "boom" end)])

    assert Report.status(report) == :error
  end

  test "a rule that runs past the timeout is stopped and the rest still run" do
    rules = [
      Rule.new(:quick, "quick", fn _ -> :ok end),
      Rule.new(:slow, "slow", fn _ -> Process.sleep(:infinity) end),
      Rule.new(:after, "after", fn _ -> :ok end)
    ]

    report = Runner.run(Commit.new(after: %{}), rules, timeout: 50)

    assert [
             %{rule: %{id: :quick}, outcome: :pass},
             %{
               rule: %{id: :slow},
               outcome: {:error, %Presubmit.RuleTimeoutError{rule: :slow, timeout: 50}, []}
             },
             %{rule: %{id: :after}, outcome: :pass}
           ] = report.results

    assert Report.status(report) == :error

    text = [report] |> Formatter.render(:text) |> IO.iodata_to_binary()
    assert text =~ "! slow: rule :slow did not finish within 0s and was stopped"
  end

  test "a rule that exits does not take the run down" do
    rules = [
      Rule.new(:exits, "exits", fn _ -> exit(:boom) end),
      Rule.new(:ok, "ok", fn _ -> :ok end)
    ]

    report = Runner.run(Commit.new(after: %{}), rules)

    assert [
             %{outcome: {:error, %RuntimeError{message: "rule exited: :boom"}, _}},
             %{outcome: :pass}
           ] = report.results
  end

  test "a result sent just before the timeout kill never lingers in the mailbox" do
    # The rule finishes right around the deadline, so the worker may send its result before it is killed.
    for _ <- 1..20 do
      Runner.run(Commit.new(after: %{}), [Rule.new(:edge, "edge", fn _ -> Process.sleep(5) end)],
        timeout: 5
      )
    end

    assert {:message_queue_len, 0} = Process.info(self(), :message_queue_len)
  end

  test "run_range/3 runs every non-merge commit oldest first", %{repo: repo} do
    reports =
      Runner.run_range(
        repo,
        "main..scenario/pure_move",
        Presubmit.RuleSet.expand(Rules.Elixir)
      )

    assert [%Report{commit: %{message: %{subject: "Move Shop.Cart under Shop.Checkout"}}}] =
             reports

    assert Report.status(hd(reports)) == :pass
  end

  describe "Formatter" do
    test "text names the source, lists outcomes, indents failures, and summarises" do
      text =
        Runner.run(Commit.new(after: %{}), rules())
        |> List.wrap()
        |> Formatter.render(:text)
        |> IO.iodata_to_binary()

      assert text =~ "Examining synthetic change set\n"
      assert text =~ "\n  ✓ passes\n"
      assert text =~ "\n  ⚠ warns (warning)\n      meh\n"
      assert text =~ "\n  ✗ fails\n      line one\n\n      line three\n"
      assert text =~ "\n  - skips (skipped: not configured)\n"
      assert text =~ "4 rules: 1 passed, 1 failed, 1 warned, 1 skipped\n"
    end

    test "text announces a commit's own exemption" do
      commit = Commit.new(after: %{}, message: "s\n\nPresubmit-Skip: bad\n")
      text = [Runner.run(commit, rules())] |> Formatter.render(:text) |> IO.iodata_to_binary()

      assert text =~
               "Examining synthetic change set\n  Presubmit-Skip: bad — skipped by the commit's own declaration\n\n"

      assert text =~ "  - fails (skipped: exempted by the commit's Presubmit-Skip trailer)\n"
      refute text =~ "✗"
    end

    test "text describes commits, the index, and the working tree", %{repo: repo} do
      commit = Commit.rev("scenario/pure_move", repo: repo)

      assert Formatter.describe(commit) ==
               "#{String.slice(commit.sha, 0, 7)} Move Shop.Cart under Shop.Checkout"

      assert Formatter.describe(%{
               commit
               | source: :worktree,
                 changes: [hd(commit.changes)],
                 message: nil
             }) ==
               "working tree (1 file differs from HEAD)"

      assert Formatter.describe(%{commit | source: :worktree, changes: [hd(commit.changes)]}) ==
               "working tree (1 file differs from HEAD) — Move Shop.Cart under Shop.Checkout"

      assert Formatter.describe(%{commit | source: :staged, message: nil}) ==
               "staged index (2 files differ from HEAD)"

      assert Formatter.describe(%{commit | source: :staged, message: nil, base: "HEAD^"}) ==
               "staged index (2 files differ from HEAD^)"
    end

    test "json carries the same fields", %{repo: repo} do
      commit = Commit.rev("scenario/pure_move", repo: repo)
      json = [Runner.run(commit, rules())] |> Formatter.render(:json) |> IO.iodata_to_binary()
      assert json =~ ~s|"source":"rev"|
      assert json =~ ~s|"sha":"#{commit.sha}"|
      assert json =~ ~s|"status":"fail"|
      assert json =~ ~s|{"id":"soft","message":"meh","name":"warns","set":"nil","status":"warn"}|

      assert json =~
               ~s|{"id":"bad","message":"line one\\n\\nline three","name":"fails","set":"nil","status":"fail"}|
    end
  end
end
