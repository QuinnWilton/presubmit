defmodule Presubmit.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/QuinnWilton/presubmit"

  def project do
    [
      app: :presubmit,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt"
      ],

      # Hex
      description: "A linter for git commits, with Elixir-aware models of what changed",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        Running: [
          Presubmit,
          Presubmit.CLI,
          Presubmit.Config,
          Presubmit.Runner,
          Presubmit.Formatter,
          Presubmit.Hooks
        ],
        Rules: [Presubmit.Rule, Presubmit.RuleSet, ~r/^Presubmit\.Rules\./],
        Assertions: [~r/^Presubmit\.Assertions/, Presubmit.Query, Presubmit.Violation],
        Adapters: [Presubmit.Adapter, ~r/^Presubmit\.Adapters\./],
        "Source analysis": [
          ~r/^Presubmit\.Source/,
          Presubmit.MixFile,
          Presubmit.Changelog
        ],
        "Change sets": [
          Presubmit.Commit,
          Presubmit.Tree,
          Presubmit.FileChange,
          Presubmit.Hunk,
          Presubmit.Message,
          Presubmit.Pattern,
          Presubmit.Paths,
          Presubmit.Git
        ],
        Errors: [~r/Error$/]
      ]
    ]
  end
end
