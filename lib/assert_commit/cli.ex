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
    list: :boolean
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
        {0, list(load_config(opts))}

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
    config = load_config(opts)
    format = format(Keyword.get(opts, :format, "text"))
    color? = Keyword.get(opts, :color, format == :text and IO.ANSI.enabled?())

    {reports, notes} =
      case source(opts, repo) do
        {:range, range} ->
          {Runner.run_range(repo, range, config.rules), []}

        source ->
          commit = AssertCommit.load(repo: repo, source: source)
          {[Runner.run(commit, config.rules)], ci_note(source, commit, env)}
      end

    status = if Enum.all?(reports, &(Report.status(&1) == :pass)), do: 0, else: 1
    output = [Enum.map(notes, &(&1 <> "\n")), Formatter.render(reports, format, color: color?)]
    {status, output}
  end

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

  defp load_config(opts) do
    Config.load!(
      repo: opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand(),
      config: Keyword.get(opts, :config)
    )
  end

  defp list(%Config{sets: sets}) do
    Enum.map_join(sets, "\n\n", fn spec ->
      {module, set_opts} = if is_atom(spec), do: {spec, []}, else: spec
      rules = AssertCommit.RuleSet.expand(spec)
      header = "#{inspect(module)}#{if set_opts == [], do: "", else: " " <> inspect(set_opts)}"
      Enum.join([header | Enum.map(rules, &"  #{&1.id} — #{&1.name}")], "\n")
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
        --repo PATH       repository to examine (default: current directory)
        --config PATH     rule configuration (default: .assert_commit.exs, or built-in defaults)
        --format FORMAT   text (default) or json
        --[no-]color      force colour on or off
        --list            print the configured rule sets and rules
      """
  end
end
