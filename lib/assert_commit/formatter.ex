defmodule AssertCommit.Formatter do
  @moduledoc """
  Renders runner reports as text or JSON.

  Every rendering starts by naming the change set it examined — the source
  and revision — so a reader can never mistake a working-tree run for a
  commit gate.
  """

  alias AssertCommit.{Commit, JSON, Query}
  alias AssertCommit.Runner.{Report, Result}

  @type format :: :text | :json

  @doc "Renders one or more reports."
  @spec render([Report.t()], format(), keyword()) :: iodata()
  def render(reports, format, opts \\ [])

  def render(reports, :text, opts) do
    color? = Keyword.get(opts, :color, false)
    Enum.map_intersperse(reports, "\n", &text(&1, color?))
  end

  def render(reports, :json, opts) do
    config =
      case Keyword.get(opts, :config) do
        %AssertCommit.Config{path: path, detection: detection} ->
          %{
            path: path,
            defaults: is_nil(path),
            detection:
              Enum.map(detection, fn {m, status, reasons} ->
                %{set: inspect(m), status: status, reasons: reasons}
              end)
          }

        nil ->
          nil
      end

    JSON.encode(%{
      config: config,
      notes: Keyword.get(opts, :notes, []),
      reports: Enum.map(reports, &json/1)
    })
  end

  @doc "One line describing what a report examined."
  @spec describe(Commit.t()) :: String.t()
  def describe(%Commit{source: :worktree} = c),
    do: "working tree (#{differ(c)} from #{c.base || "HEAD"})#{with_subject(c)}"

  def describe(%Commit{source: :staged} = c),
    do: "staged index (#{differ(c)} from #{c.base || "HEAD"})#{with_subject(c)}"

  def describe(%Commit{source: :synthetic}), do: "synthetic change set"
  def describe(%Commit{sha: sha} = c), do: "#{short(sha)} #{Query.subject(c)}"

  defp text(%Report{commit: commit} = report, color?) do
    counts = Report.counts(report)

    lines =
      ["Examining #{describe(commit)}", ""] ++
        Enum.flat_map(report.results, &result_lines(&1, color?)) ++
        ["", summary(counts, Report.status(report), color?)]

    Enum.map_join(lines, "\n", & &1) <> "\n"
  end

  defp result_lines(%Result{rule: rule, outcome: :pass}, color?),
    do: [paint("  ✓ #{rule.name}", :green, color?)]

  defp result_lines(%Result{rule: rule, outcome: {:skip, reason}}, color?),
    do: [paint("  - #{rule.name} (skipped: #{reason})", :faint, color?)]

  defp result_lines(%Result{rule: rule, outcome: {:fail, message}}, color?) do
    [paint("  ✗ #{rule.name}", :red, color?) | indent(message)]
  end

  defp result_lines(%Result{rule: rule, outcome: {:error, exception, stack}}, color?) do
    [
      paint("  ! #{rule.name} raised #{inspect(exception.__struct__)}", :red, color?)
      | indent(Exception.format(:error, exception, stack))
    ]
  end

  defp indent(text),
    do: text |> String.split("\n") |> Enum.map(&if(&1 == "", do: "", else: "      " <> &1))

  defp summary(counts, status, color?) do
    total = counts.pass + counts.fail + counts.skip + counts.error

    parts =
      [
        {counts.pass, "passed"},
        {counts.fail, "failed"},
        {counts.skip, "skipped"},
        {counts.error, "errored"}
      ]
      |> Enum.reject(&(elem(&1, 0) == 0))
      |> Enum.map_join(", ", fn {n, word} -> "#{n} #{word}" end)

    color = if status == :pass, do: :green, else: :red
    paint("#{plural(total, "rule")}: #{parts}", color, color?)
  end

  defp json(%Report{commit: commit} = report) do
    %{
      source: commit.source,
      sha: commit.sha,
      subject: if(commit.message, do: commit.message.subject),
      status: Report.status(report),
      counts: Report.counts(report),
      results:
        Enum.map(report.results, fn %Result{rule: rule, outcome: outcome} ->
          base = %{set: inspect(rule.set), id: rule.id, name: rule.name}

          case outcome do
            :pass -> Map.put(base, :status, :pass)
            {:fail, message} -> Map.merge(base, %{status: :fail, message: message})
            {:skip, reason} -> Map.merge(base, %{status: :skip, message: reason})
            {:error, e, _} -> Map.merge(base, %{status: :error, message: Exception.message(e)})
          end
        end)
    }
  end

  defp paint(text, _color, false), do: text
  defp paint(text, color, true), do: IO.ANSI.format([color, text]) |> IO.iodata_to_binary()

  defp with_subject(%Commit{message: nil}), do: ""
  defp with_subject(%Commit{message: %{subject: subject}}), do: " — #{subject}"

  defp differ(%Commit{changes: [_]}), do: "1 file differs"
  defp differ(%Commit{changes: changes}), do: "#{length(changes)} files differ"

  defp short(nil), do: "(no sha)"
  defp short(sha), do: String.slice(sha, 0, 7)

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"
end
