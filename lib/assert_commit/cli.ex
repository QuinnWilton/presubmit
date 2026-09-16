defmodule AssertCommit.CLI do
  @moduledoc """
  The logic behind `mix assert_commit`, separated from Mix so it can be
  driven from tests: parse arguments, load configuration and change sets,
  run, render, and return an exit status.
  """

  alias AssertCommit.{Config, Formatter, Runner}
  alias AssertCommit.Runner.Report

  @switches [
    staged: :boolean,
    worktree: :boolean,
    head: :boolean,
    rev: :string,
    range: :string,
    repo: :string,
    config: :string,
    format: :string,
    color: :boolean,
    list: :boolean,
    message: :string,
    message_file: :string,
    base: :string,
    on_error: :string,
    timeout: :integer,
    warnings_as_errors: :boolean
  ]

  @type result :: {exit_status :: 0 | 1 | 2, output :: iodata()}

  @doc "Runs the command line and returns `{exit_status, output}`."
  @spec main([String.t()], keyword()) :: result()
  def main(argv, env \\ []) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    cond do
      invalid != [] or rest != [] ->
        {2, usage("unknown arguments: #{Enum.map_join(invalid ++ rest, " ", &format_arg/1)}")}

      Keyword.get(opts, :list) ->
        {0, list(load_config(opts, list_commit(opts)))}

      true ->
        run(opts, env)
    end
  rescue
    e in [
      Config.Error,
      AssertCommit.GitError,
      AssertCommit.MergeCommitError,
      AssertCommit.ShallowCloneError
    ] ->
      {2, "error: " <> Exception.message(e) <> "\n"}
  end

  defp run(opts, env) do
    repo = opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand()
    format = format(Keyword.get(opts, :format, "text"))
    color? = Keyword.get(opts, :color, format == :text and IO.ANSI.enabled?())

    {config, reports, notes} =
      case source(opts, repo) do
        {:range, range} ->
          # Detection reads the tree at the end of the range.
          config =
            load_config(opts, AssertCommit.load(repo: repo, source: {:rev, range_end(range)}))

          {config, Runner.run_range(repo, range, config.rules, timeout: timeout(opts)), []}

        source ->
          commit =
            AssertCommit.load(
              repo: repo,
              source: source,
              message: message(opts, source),
              base: base(opts, source)
            )

          config = load_config(opts, commit)

          {config, [Runner.run(commit, config.rules, timeout: timeout(opts))],
           ci_note(source, commit, env)}
      end

    status = exit_status(reports, on_error(opts), Keyword.get(opts, :warnings_as_errors, false))

    output =
      case format do
        :text ->
          [
            Enum.map(notes ++ config_notes(config), &(&1 <> "\n")),
            Formatter.render(reports, :text, color: color?)
          ]

        :json ->
          Formatter.render(reports, :json, config: config, notes: notes)
      end

    {status, output}
  end

  # A crashed rule is a bug in the tool, not in the commit; hooks ask for it to be a warning.
  defp exit_status(reports, on_error, warnings_as_errors?) do
    statuses = Enum.map(reports, &Report.status/1)

    cond do
      :fail in statuses -> 1
      :error in statuses and on_error == :fail -> 1
      warnings_as_errors? and Enum.any?(reports, &Report.warnings?/1) -> 1
      true -> 0
    end
  end

  defp timeout(opts) do
    case Keyword.get(opts, :timeout, 30) do
      seconds when is_integer(seconds) and seconds > 0 ->
        seconds * 1000

      other ->
        raise Config.Error,
          message: "--timeout must be a positive number of seconds, got #{inspect(other)}"
    end
  end

  defp on_error(opts) do
    case Keyword.get(opts, :on_error, "fail") do
      "fail" -> :fail
      "warn" -> :warn
      other -> raise Config.Error, message: "unknown --on-error #{other}; use fail or warn"
    end
  end

  # With no configuration file the defaults depend on detection, so say what was decided.
  defp config_notes(%Config{path: nil, detection: detection}) do
    enabled = for {m, :enabled, reasons} <- detection, do: "#{set_name(m)}#{because(reasons)}"

    disabled =
      for {m, :disabled, reasons} <- detection, do: "#{set_name(m)} (#{Enum.join(reasons, "; ")})"

    ["No .assert_commit.exs; using built-in defaults.", "  enabled: #{Enum.join(enabled, ", ")}"] ++
      if(disabled == [], do: [], else: ["  not enabled: #{Enum.join(disabled, ", ")}"]) ++ [""]
  end

  defp config_notes(%Config{}), do: []

  defp because([]), do: ""
  defp because(reasons), do: " (#{Enum.join(reasons, "; ")})"

  defp set_name(module),
    do: module |> inspect() |> String.replace_prefix("AssertCommit.Rules.", "")

  # A message may only be attached where there is none yet; commits already have theirs.
  defp message(opts, source) do
    text =
      case {Keyword.get(opts, :message), Keyword.get(opts, :message_file)} do
        {nil, nil} -> nil
        {text, nil} -> text
        {nil, path} -> read_message_file(path)
        {_, _} -> raise Config.Error, message: "pass either --message or --message-file, not both"
      end

    if text != nil and source not in [:staged, :worktree] do
      raise Config.Error,
        message:
          "--message only applies to --staged or --worktree; a commit already has its message"
    end

    text
  end

  defp base(opts, source) do
    case Keyword.get(opts, :base) do
      nil -> nil
      base when source in [:staged, :worktree] -> base
      _ -> raise Config.Error, message: "--base only applies to --staged or --worktree"
    end
  end

  defp read_message_file(path) do
    case File.read(path) do
      {:ok, text} ->
        text

      {:error, reason} ->
        raise Config.Error,
          message: "cannot read --message-file #{path}: #{:file.format_error(reason)}"
    end
  end

  defp range_end(range), do: range |> String.split("..") |> List.last()

  defp source(opts, repo) do
    explicit =
      Enum.filter([:staged, :worktree, :head, :rev, :range], &Keyword.has_key?(opts, &1))

    case explicit do
      [] ->
        AssertCommit.resolve_source(repo: repo, source: :auto)

      [:staged] ->
        :staged

      [:worktree] ->
        :worktree

      [:head] ->
        :head

      [:rev] ->
        {:rev, Keyword.fetch!(opts, :rev)}

      [:range] ->
        {:range, Keyword.fetch!(opts, :range)}

      many ->
        raise Config.Error, message: "choose one of #{Enum.map_join(many, ", ", &"--#{&1}")}"
    end
  end

  # `--worktree` inferred under CI almost always means a build step dirtied the checkout.
  defp ci_note(source, commit, env) do
    ci? = Keyword.get_lazy(env, :ci, fn -> System.get_env("CI") not in [nil, "", "false"] end)

    if ci? and source == :worktree do
      [
        "warning: the working tree differs from HEAD in #{length(commit.changes)} file(s) and CI is set; " <>
          "examining the working tree. Pass --rev HEAD (or --head) to gate the commit itself."
      ]
    else
      []
    end
  end

  defp load_config(opts, commit) do
    Config.load!(
      repo: opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand(),
      config: Keyword.get(opts, :config),
      commit: commit
    )
  end

  # --list needs a tree for detection; HEAD is the natural one, and an unborn repo just has none.
  defp list_commit(opts) do
    AssertCommit.load(
      repo: opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand(),
      source: :head
    )
  rescue
    _ -> nil
  end

  defp list(%Config{sets: sets} = config) do
    "Rules see source shapes only: functions, routes, schemas, and children produced by macros\n" <>
      "are invisible to them, and a rule that depends on such code passes vacuously.\n\n" <>
      Enum.join(config_notes(config), "\n") <>
      Enum.map_join(sets, "\n\n", fn spec ->
        {module, set_opts} = if is_atom(spec), do: {spec, []}, else: spec
        rules = AssertCommit.RuleSet.expand(spec)
        header = "#{inspect(module)}#{if set_opts == [], do: "", else: " " <> inspect(set_opts)}"

        Enum.join(
          [
            header
            | Enum.map(
                rules,
                &"  #{&1.id}#{if &1.severity == :warn, do: " (warn)", else: ""} — #{&1.name}"
              )
          ],
          "\n"
        )
      end) <> "\n"
  end

  defp format("text"), do: :text
  defp format("json"), do: :json

  defp format(other),
    do: raise(Config.Error, message: "unknown --format #{other}; use text or json")

  defp format_arg({flag, nil}), do: flag
  defp format_arg({flag, value}), do: "#{flag}=#{value}"
  defp format_arg(arg), do: arg

  @doc false
  @spec usage(String.t() | nil) :: String.t()
  def usage(error \\ nil) do
    if(error, do: "error: #{error}\n\n", else: "") <>
      """
      Usage: mix assert_commit [source] [options]

      Sources (default: --worktree when anything on disk differs from HEAD, else --head):
        --head            the commit at HEAD
        --rev REV         any revision
        --staged          the index, against HEAD
        --worktree        the working directory, against HEAD
        --range A..B      every non-merge commit in a rev-list range

      Options:
        --message-file P  attach the message in file P to a --staged/--worktree change set (commit-msg hook)
        --message TEXT    attach TEXT as the message
        --base REV        measure --staged/--worktree against REV instead of HEAD (HEAD^ while amending)
        --repo PATH       repository to examine (default: current directory)
        --config PATH     rule configuration (default: .assert_commit.exs, or built-in defaults)
        --format FORMAT   text (default) or json
        --[no-]color      force colour on or off
        --on-error MODE   fail (default) or warn: whether a rule that crashes affects the exit status
        --timeout SECS    stop a rule that runs longer than this (default 30) and report it as an error
        --warnings-as-errors  exit 1 when any rule warned
        --list            print the configured rule sets and rules
      """
  end
end
