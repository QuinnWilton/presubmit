# The dogfood suite asserts on this repository's own HEAD, which needs a
# commit with a parent. Skip it in a fresh checkout or a depth-1 clone.
dogfood? =
  match?(
    {_, 0},
    System.cmd("git", ["rev-parse", "--verify", "--quiet", "HEAD~1"], stderr_to_stdout: true)
  )

unless dogfood? do
  IO.puts("[presubmit] HEAD~1 is unavailable; excluding :dogfood tests")
end

ExUnit.start(exclude: if(dogfood?, do: [], else: [:dogfood]))
