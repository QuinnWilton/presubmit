defmodule AssertCommit.RuleSetTest do
  use ExUnit.Case, async: true

  alias AssertCommit.{Commit, Rule, RuleSet}

  defmodule Sample do
    use AssertCommit.RuleSet

    rule :always, "always passes", fn _commit -> :ok end
    rule :never, "always fails", fn _commit -> raise AssertCommit.Violation, message: "nope" end

    rule :with_opts, "reads options", fn _commit, opts ->
      if Keyword.get(opts, :strict),
        do: raise(AssertCommit.Violation, message: "strict"),
        else: :ok
    end

    rule :skips, "skips when unconfigured", fn _commit, opts ->
      if Keyword.has_key?(opts, :thing), do: :ok, else: {:skip, "no thing"}
    end

    rule :crashes, "raises something else", fn _commit -> raise ArgumentError, "boom" end
  end

  defp commit, do: Commit.new(after: %{"a" => "a\n"}, message: "s")

  test "rules/1 returns rules in declaration order with the set and options attached" do
    assert Enum.map(Sample.rules(strict: true), &{&1.id, &1.set, &1.opts}) ==
             [
               {:always, Sample, [strict: true]},
               {:never, Sample, [strict: true]},
               {:with_opts, Sample, [strict: true]},
               {:skips, Sample, [strict: true]},
               {:crashes, Sample, [strict: true]}
             ]
  end

  test "expand/1 applies only: and except: and passes the rest through" do
    assert Enum.map(RuleSet.expand(Sample), & &1.id) == [
             :always,
             :never,
             :with_opts,
             :skips,
             :crashes
           ]

    assert Enum.map(RuleSet.expand({Sample, only: [:always, :skips]}), & &1.id) == [
             :always,
             :skips
           ]

    assert Enum.map(RuleSet.expand({Sample, except: [:never, :crashes]}), & &1.id) == [
             :always,
             :with_opts,
             :skips
           ]

    assert [%Rule{opts: [strict: true]}] =
             RuleSet.expand({Sample, only: [:with_opts], strict: true})
  end

  test "expand/1 rejects unknown rule ids and non-rule-sets" do
    assert_raise ArgumentError, ~r/has no rule :nope; it has \[:always/, fn ->
      RuleSet.expand({Sample, only: [:nope]})
    end

    assert_raise ArgumentError, ~r/is not a rule set/, fn -> RuleSet.expand(Enum) end
  end

  test "Rule.run/2 maps outcomes" do
    run = fn id, opts ->
      Sample |> then(&RuleSet.expand({&1, [only: [id]] ++ opts})) |> hd() |> Rule.run(commit())
    end

    assert run.(:always, []) == :pass
    assert run.(:never, []) == {:fail, "nope"}
    assert run.(:with_opts, []) == :pass
    assert run.(:with_opts, strict: true) == {:fail, "strict"}
    assert run.(:skips, []) == {:skip, "no thing"}
    assert run.(:skips, thing: 1) == :pass
    assert {:error, %ArgumentError{message: "boom"}, [_ | _]} = run.(:crashes, [])
  end

  test "message rules skip on change sets without a message" do
    rule = AssertCommit.Rules.Message |> then(&RuleSet.expand({&1, only: [:no_fixup]})) |> hd()
    assert {:skip, reason} = Rule.run(rule, Commit.new(after: %{}))
    assert reason =~ "needs a commit message"
  end
end
