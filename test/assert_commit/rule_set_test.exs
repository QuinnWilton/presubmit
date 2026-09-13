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
    rule(:committed_only, "only on commits", fn _commit -> :ok end, sources: [:head, :rev])
  end

  defp commit, do: Commit.new(after: %{"a" => "a\n"}, message: "s")

  test "rules/1 returns rules in declaration order with the set and options attached" do
    assert Enum.map(Sample.rules(strict: true), &{&1.id, &1.set, &1.opts}) ==
             [
               {:always, Sample, [strict: true]},
               {:never, Sample, [strict: true]},
               {:with_opts, Sample, [strict: true]},
               {:skips, Sample, [strict: true]},
               {:crashes, Sample, [strict: true]},
               {:committed_only, Sample, [strict: true]}
             ]
  end

  test "expand/1 applies only: and except: and passes the rest through" do
    assert Enum.map(RuleSet.expand(Sample), & &1.id) == [
             :always,
             :never,
             :with_opts,
             :skips,
             :crashes,
             :committed_only
           ]

    assert Enum.map(RuleSet.expand({Sample, only: [:always, :skips]}), & &1.id) == [
             :always,
             :skips
           ]

    assert Enum.map(
             RuleSet.expand({Sample, except: [:never, :crashes, :committed_only]}),
             & &1.id
           ) == [
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

  describe "requires/0 and applicable?/2" do
    defmodule NeedsPhoenix do
      use AssertCommit.RuleSet, requires: [{:phoenix, Phoenix.Router}, {:file, "CHANGELOG.md"}]
      rule :x, "x", fn _ -> :ok end
    end

    defp env(loaded, deps, files) do
      %{loaded?: &(&1 in loaded), deps: deps, file?: &(&1 in files)}
    end

    test "sets require nothing unless they say so" do
      assert Sample.requires() == []
      assert RuleSet.applicable?(Sample, env([], [], [])) == {:ok, []}
    end

    test "an app requirement is met by a loaded module or a declared dependency" do
      assert {:ok, ["Phoenix.Router loaded", "CHANGELOG.md present"]} =
               RuleSet.applicable?(NeedsPhoenix, env([Phoenix.Router], [], ["CHANGELOG.md"]))

      assert {:ok, ["phoenix is a dependency", _]} =
               RuleSet.applicable?(NeedsPhoenix, env([], [:phoenix], ["CHANGELOG.md"]))
    end

    test "missing requirements are reported with reasons" do
      assert {:missing, reasons} = RuleSet.applicable?(NeedsPhoenix, env([], [], []))

      assert reasons == [
               "phoenix not a dependency and Phoenix.Router not loaded",
               "no CHANGELOG.md"
             ]
    end
  end

  test "message rules skip on change sets without a message" do
    rule =
      AssertCommit.Rules.Message |> then(&RuleSet.expand({&1, only: [:subject_length]})) |> hd()

    assert {:skip, reason} = Rule.run(rule, Commit.new(after: %{}))
    assert reason =~ "needs a commit message"
  end

  test "a rule with sources: is skipped elsewhere" do
    [rule] = RuleSet.expand({Sample, only: [:committed_only]})
    assert rule.sources == [:head, :rev]
    assert {:skip, "only checked on :head/:rev change sets"} = Rule.run(rule, commit())
    assert :pass = Rule.run(rule, %{commit() | source: :head})
  end
end
