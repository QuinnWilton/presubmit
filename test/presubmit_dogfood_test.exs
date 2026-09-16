defmodule PresubmitDogfoodTest do
  @moduledoc """
  Runs this repository's own `.presubmit.exs` against its `HEAD`, the way
  CI does with `mix presubmit --head`. Excluded when `HEAD~1` is
  unavailable (fresh checkout or depth-1 clone); see `test/test_helper.exs`.
  """

  use ExUnit.Case, async: true

  alias Presubmit.{Config, Formatter, Runner}
  alias Presubmit.Runner.Report

  @moduletag :dogfood

  test "HEAD satisfies the project's commit policy" do
    root = Path.expand("..", __DIR__)
    config = Config.load!(repo: root)
    assert config.path == Path.join(root, ".presubmit.exs")

    report = Runner.run(Presubmit.load(repo: root, source: :head), config.rules)

    assert Report.status(report) == :pass,
           [report] |> Formatter.render(:text) |> IO.iodata_to_binary()
  end
end
