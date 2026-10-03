defmodule Presubmit.Scenarios.MessageTest do
  @moduledoc """
  `Rules.Message` run against `fixtures/message`: a multi-project repository
  whose `[component]` subjects must agree with the paths touched, whose
  LLM-assisted commits must be attributed, and whose tooling manifest can
  only change with the tooling's trailer.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Presubmit.Query
  import Presubmit.RuleHelpers

  alias Presubmit.{Fixtures, Rules}

  setup_all do: %{repo: Fixtures.repo("message")}

  # A `[component]` commit may touch that component's directory; `[workspace]` may touch anything.
  defp scope_opts do
    paths = fn
      "workspace" -> nil
      "deps" -> [~r{^\.tooling/}, "mix.lock"]
      component -> ~r{^#{Regex.escape(component)}/}
    end

    [scope: {~r/^\[(\w+)\]/, paths}]
  end

  # A Co-Authored-By naming the model is the trigger; the session link is the required companion.
  defp llm_opts do
    llm? = fn commit ->
      Enum.any?(trailer(commit, "Co-Authored-By"), &(&1 =~ ~r/anthropic\.com/))
    end

    [trailers: [{llm?, "Claude-Session", ~r{^https://claude\.ai/code/session_}}]]
  end

  defp tooling_opts, do: [trailers: [{&touches?(&1, ~r{^\.tooling/}), "Tooling", nil}]]

  describe ":scope" do
    test "passes", %{repo: repo} do
      assert_pass run_rule(Rules.Message, :scope, scenario(repo, :scoped_correctly), scope_opts())
    end

    test "fails when the diff is in another component", %{repo: repo} do
      commit = scenario(repo, :scope_mismatch)
      [scope] = Regex.run(~r/^\[(\w+)\]/, subject(commit), capture: :all_but_first)
      [path] = touched(commit)
      assert_fail run_rule(Rules.Message, :scope, commit, scope_opts()), message
      assert message =~ "scopes this commit to #{inspect(scope)}"
      assert message =~ "but it also touches:\n  #{path}"
    end

    test "fails when there is no scope at all", %{repo: repo} do
      assert_fail run_rule(Rules.Message, :scope, scenario(repo, :no_scope), scope_opts()),
                  message

      assert message =~ "Expected the subject to declare a scope"
    end

    test "catches a commit spanning two components", %{repo: repo} do
      commit = scenario(repo, :multi_project)
      assert length(touched(commit)) == 2
      assert_fail run_rule(Rules.Message, :scope, commit, scope_opts()), _
    end

    test "is skipped when not configured", %{repo: repo} do
      assert {:skip, "no scope: option configured"} =
               run_rule(Rules.Message, :scope, scenario(repo, :no_scope))
    end
  end

  describe ":trailers for LLM-assisted commits" do
    test "passes with both trailers", %{repo: repo} do
      commit = scenario(repo, :llm_commit_attributed)
      assert length(trailers(commit)) == 2
      assert_pass run_rule(Rules.Message, :trailers, commit, llm_opts())
    end

    test "fails without the session link", %{repo: repo} do
      assert_fail run_rule(
                    Rules.Message,
                    :trailers,
                    scenario(repo, :llm_commit_missing_session),
                    llm_opts()
                  ),
                  message

      assert message =~
               "Expected a `Claude-Session:` trailer, but the message has only: Co-Authored-By."
    end

    test "trailers followed by prose are not trailers, so the trigger never fires", %{repo: repo} do
      commit = scenario(repo, :trailers_not_last)
      assert trailers(commit) == []
      assert_pass run_rule(Rules.Message, :trailers, commit, llm_opts())

      # The generic verb explains why the block was not recognised.
      error =
        assert_raise Presubmit.Violation, fn ->
          Presubmit.Assertions.assert_trailer(commit, "Co-Authored-By")
        end

      assert error.message =~
               "Trailers are `Key: value` lines in the final paragraph of the message."
    end

    test "human commits are not required to carry the trailer", %{repo: repo} do
      assert_pass run_rule(
                    Rules.Message,
                    :trailers,
                    scenario(repo, :scoped_correctly),
                    llm_opts()
                  )
    end

    test "is skipped when not configured", %{repo: repo} do
      assert {:skip, "no trailers: option configured"} =
               run_rule(Rules.Message, :trailers, scenario(repo, :scoped_correctly))
    end
  end

  describe ":trailers for a tooling-owned file" do
    test "passes when the tooling trailer is present", %{repo: repo} do
      assert_pass run_rule(
                    Rules.Message,
                    :trailers,
                    scenario(repo, :manifest_via_tooling),
                    tooling_opts()
                  )
    end

    test "fails on a hand edit", %{repo: repo} do
      assert_fail run_rule(
                    Rules.Message,
                    :trailers,
                    scenario(repo, :manifest_hand_edit),
                    tooling_opts()
                  ),
                  message

      assert message =~ "Expected a `Tooling:` trailer"
    end

    test "is vacuous when the manifest is untouched", %{repo: repo} do
      assert_pass run_rule(
                    Rules.Message,
                    :trailers,
                    scenario(repo, :scoped_correctly),
                    tooling_opts()
                  )
    end
  end

  describe ":body_line_length" do
    # A prose sentence of `n` characters, made of short words, so wrapping always helps.
    defp prose(n),
      do:
        String.duplicate("word ", div(n, 5) + 1)
        |> String.slice(0, n)
        |> String.trim_trailing()
        |> pad(n)

    defp pad(text, n), do: text <> String.duplicate("x", n - String.length(text))

    defp message(body),
      do: Presubmit.Commit.new(before: %{}, after: %{"a" => "1\n"}, message: body)

    defp body_rule(raw, opts \\ []),
      do: run_rule(Rules.Message, :body_line_length, message(raw), opts)

    test "passes a body wrapped at 72 and a message without a body" do
      assert_pass body_rule("[x] subject\n\n#{prose(72)}\n#{prose(40)}\n")
      assert_pass body_rule("[x] subject\n")
    end

    test "fails an unwrapped paragraph, naming each line, its length, and its start" do
      raw = "[x] subject\n\n#{prose(72)}\n\n#{prose(190)}\n#{prose(73)}\n"
      assert_fail body_rule(raw), message

      assert message =~
               "2 body lines are longer than 72 characters; wrap prose at 72 columns:"

      assert message =~
               ~s(line 5: 190 characters, 118 over: "word word word word word word word word…")

      assert message =~ "line 6: 73 characters, 1 over:"
      refute message =~ "line 3:"
    end

    test "a single long line reads in the singular" do
      assert_fail body_rule("[x] s\n\n#{prose(80)}"), message
      assert message =~ "1 body line is longer than 72 characters"
    end

    test "max_body_line_length: sets the limit" do
      raw = "[x] subject\n\n#{prose(100)}\n"
      assert_fail body_rule(raw), _
      assert_pass body_rule(raw, max_body_line_length: 100)
      assert_fail body_rule(raw, max_body_line_length: 99), message
      assert message =~ "line 3: 100 characters, 1 over:"
    end

    test "counts characters, not bytes" do
      fits = String.duplicate("séance ≡ ", 8) |> String.trim_trailing() |> pad(72)
      assert String.length(fits) == 72 and byte_size(fits) > 72
      assert_pass body_rule("[x] s\n\n#{fits}\n")
      assert_fail body_rule("[x] s\n\n#{fits} é\n"), message
      assert message =~ "74 characters, 2 over"
    end

    test "trailers in the trailer block are not measured" do
      session = "Claude-Session: https://claude.ai/code/session_" <> String.duplicate("e9c3", 10)
      assert String.length(session) > 72

      assert_pass body_rule(
                    "[x] s\n\n#{prose(60)}\n\nCo-Authored-By: Someone With A Long Name <someone.with.a.long.name@example.com>\n#{session}\n"
                  )
    end

    test "a trailer-shaped line with a one-word value outside the trailer block passes" do
      session = "Claude-Session: https://claude.ai/code/session_" <> String.duplicate("e9c3", 10)
      assert_pass body_rule("[x] s\n\n#{prose(60)}\n#{session}\nnot a trailer\n")
    end

    test "a long word after a lead-in that fits passes; a prose overflow does not" do
      url = "https://example.com/" <> String.duplicate("segment/", 10)
      assert String.length(url) > 72
      assert_pass body_rule("[x] s\n\n#{url}\n")
      assert_pass body_rule("[x] s\n\nSee #{url}\n")
      assert_pass body_rule("[x] s\n\n/very/long/path/" <> String.duplicate("dir/", 20) <> "\n")

      # A short URL moves to the next line and fits there.
      assert_fail body_rule("[x] s\n\n#{prose(60)} https://example.com/a/b\n"), _
      # A long lead-in wraps even when the last word is a long URL.
      assert_fail body_rule("[x] s\n\n#{prose(80)} #{url}\n"), _
      # Prose over by one word wraps.
      assert_fail body_rule("[x] s\n\n#{prose(70)} word\n"), _
    end

    test "indented and quoted lines pass" do
      long = prose(100)
      assert_pass body_rule("[x] s\n\nCode:\n\n    #{long}\n\tdef #{long}\n")
      assert_pass body_rule("[x] s\n\n> #{long}\n>#{long}\n")
    end

    test "trailing whitespace is not counted" do
      assert_pass body_rule("[x] s\n\n#{prose(72)}   \n")
    end

    test "git-generated subjects are exempt unless exempt: says otherwise" do
      raw = "Revert \"[x] s\"\n\n#{prose(100)}\n"
      assert {:skip, "git-generated subject: " <> _} = body_rule(raw)
      assert_fail body_rule(raw, exempt: []), _
    end

    test "warn: reports without failing" do
      [rule] =
        Presubmit.RuleSet.expand(
          {Rules.Message, only: [:body_line_length], warn: [:body_line_length]}
        )

      assert {:warn, _} = Presubmit.Rule.run(rule, message("[x] s\n\n#{prose(100)}\n"))
    end

    property "a body whose lines all fit passes" do
      check all(
              max <- integer(20..100),
              lines <- list_of(prose_line(1, max), min_length: 1, max_length: 8)
            ) do
        assert_pass body_rule("[x] s\n\n" <> Enum.join(lines, "\n"), max_body_line_length: max)
      end
    end

    property "a body with one wrappable prose line over the limit fails, naming that line" do
      check all(
              max <- integer(20..100),
              before <- list_of(prose_line(1, max), max_length: 5),
              # Its words are shorter than any limit, so wrapping can always break it.
              over <- prose_line(max + 1, max + 120),
              rest <- list_of(prose_line(1, max), max_length: 5)
            ) do
        raw = "[x] s\n\n" <> Enum.join(before ++ [over] ++ rest, "\n")
        number = 3 + length(before)

        assert_fail body_rule(raw, max_body_line_length: max), message
        assert message =~ "1 body line is longer than #{max} characters"
        assert message =~ "line #{number}: #{String.length(over)} characters"
      end
    end
  end

  # Words of 1 to 12 letters, some non-ASCII, joined by single spaces and cut to `min..max`
  # characters: prose that wrapping can always break, since no word is as long as a limit.
  defp prose_line(min, max) do
    word = string([?a..?z, ?é, ?≡], min_length: 1, max_length: 12)

    gen all(
          words <- list_of(word, length: max),
          length <- integer(min..max)
        ) do
      line = words |> Enum.join(" ") |> String.slice(0, length)
      # A cut that lands on a space would leave trailing whitespace, which is not counted.
      String.replace(line, ~r/ $/, "x")
    end
  end
end
