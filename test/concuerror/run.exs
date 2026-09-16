# Runs every Presubmit.Concuerror.* scenario:
#   MIX_ENV=test mix run --no-start test/concuerror/run.exs
Application.load(:presubmit)

scenarios =
  :presubmit
  |> Application.spec(:modules)
  |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir.Presubmit.Concuerror."))
  |> Enum.sort()

File.mkdir_p!("_build/concuerror")

failures =
  for mod <- scenarios,
      report = ~c"_build/concuerror/#{inspect(mod)}.txt",
      IO.puts("concuerror: #{inspect(mod)} (report: #{report})"),
      # The runner kills workers that time out on purpose.
      :concuerror.run(
        entry_point: {mod, :run, []},
        output: report,
        quiet: true,
        treat_as_normal: [:killed]
      ) != :ok,
      do: mod

IO.puts(
  "concuerror: #{length(scenarios) - length(failures)}/#{length(scenarios)} scenarios passed"
)

if failures != [], do: System.halt(1)
