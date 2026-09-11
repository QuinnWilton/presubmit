defmodule AssertCommit.GitError do
  @moduledoc """
  Raised when a git command fails or its output cannot be interpreted.
  """

  defexception [:command, :status, :output, :repo]

  @type t :: %__MODULE__{
          command: [String.t()],
          status: non_neg_integer() | nil,
          output: String.t(),
          repo: Path.t()
        }

  @impl true
  def message(%__MODULE__{} = error) do
    """
    git #{Enum.join(error.command, " ")} failed in #{error.repo}\
    #{if error.status, do: " (exit #{error.status})", else: ""}:

    #{String.trim_trailing(error.output)}
    """
  end
end

defmodule AssertCommit.MergeCommitError do
  @moduledoc """
  Raised when the revision under test is a merge commit.

  A merge has no single "before" tree, so there is no well-defined set of
  changes to assert on. On GitHub `pull_request` events the checked-out
  `HEAD` is a synthetic merge of the PR into its base; assert on the PR's
  individual commits instead (`rev:` with each SHA in
  `base.sha..head.sha`), or on `github.event.pull_request.head.sha`.
  """

  defexception [:sha, :parents]

  @type t :: %__MODULE__{sha: String.t(), parents: [String.t()]}

  @impl true
  def message(%__MODULE__{sha: sha, parents: parents}) do
    """
    #{sha} is a merge commit with #{length(parents)} parents:

      #{Enum.join(parents, "\n  ")}

    assert_commit needs a single parent to compute a change set. If this is CI \
    on a pull_request event, GitHub checked out a synthetic merge commit; assert \
    on github.event.pull_request.head.sha (or on each commit in the PR range) instead.
    """
  end
end

defmodule AssertCommit.ShallowCloneError do
  @moduledoc """
  Raised when the parent of the revision under test is not present locally.

  CI checkouts default to a depth-1 clone, which contains `HEAD` but not
  `HEAD~1`, so no diff can be computed.
  """

  defexception [:sha, :parent]

  @type t :: %__MODULE__{sha: String.t(), parent: String.t() | nil}

  @impl true
  def message(%__MODULE__{sha: sha, parent: parent}) do
    parent_clause =
      if parent,
        do: "#{sha} has parent #{parent}, but that commit is not present in this clone.",
        else: "#{sha} is a shallow-clone boundary: its parent was cut off by `--depth`."

    """
    #{parent_clause}

    This is usually a shallow CI checkout. With actions/checkout, set \
    `fetch-depth: 2` to assert on HEAD, or `fetch-depth: 0` to assert on a range.
    """
  end
end

defmodule AssertCommit.NoMessageError do
  @moduledoc """
  Raised when a message assertion runs against a change set that has no
  commit message, such as the staged index.
  """

  defexception [:source]

  @type t :: %__MODULE__{source: atom()}

  @impl true
  def message(%__MODULE__{source: source}) do
    """
    This change set was built from #{inspect(source)} and has no commit message yet.

    Guard message assertions with `if AssertCommit.Query.has_message?(commit)`, \
    or run them only against committed revisions.
    """
  end
end
