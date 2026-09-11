defmodule Toolkit.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [app: :toolkit, version: @version, elixir: "~> 1.19", deps: deps()]
  end

  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end
end
