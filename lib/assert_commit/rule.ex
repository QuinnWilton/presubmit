defmodule AssertCommit.Rule do
  @moduledoc """
  One named check over a change set.

  `check` is a function of the commit (and, for configurable rules, the
  options the rule set was given) that returns `:ok` or raises
  `AssertCommit.Violation`. Rules are grouped into rule sets
  (`AssertCommit.RuleSet`) and run by `AssertCommit.Runner`.

  A rule may declare the change-set `sources` it applies to; outside them it
  is skipped. `no_fixup` is the canonical case: `fixup!` commits are meant to
  exist locally and be autosquashed, so the rule applies to committed
  revisions (`:head`, `:rev`) and not to the index a hook is checking.
  """

  alias AssertCommit.{Commit, NoMessageError, Violation}

  @enforce_keys [:id, :name, :check]
  defstruct [:id, :name, :check, set: nil, opts: [], sources: nil]

  @type check ::
          (Commit.t() -> :ok | {:skip, String.t()})
          | (Commit.t(), keyword() -> :ok | {:skip, String.t()})

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          check: check(),
          set: module() | nil,
          opts: keyword(),
          sources: [atom()] | nil
        }

  @type outcome ::
          :pass
          | {:fail, String.t()}
          | {:skip, String.t()}
          | {:error, Exception.t(), Exception.stacktrace()}

  @doc "Builds a rule."
  @spec new(atom(), String.t(), check(), keyword()) :: t()
  def new(id, name, check, attrs \\ [])
      when is_atom(id) and is_binary(name) and is_function(check) do
    struct!(__MODULE__, [id: id, name: name, check: check] ++ attrs)
  end

  @doc """
  Runs the rule against `commit`.

  A `AssertCommit.Violation` is a failure. A skip is: a
  `AssertCommit.NoMessageError` (a message rule against the index or working
  tree), a check returning `{:skip, reason}` (nothing configured), or a
  change set outside the rule's `sources`. Any other exception is reported
  as an error rather than crashing the run.
  """
  @spec run(t(), Commit.t()) :: outcome()
  def run(%__MODULE__{sources: sources} = rule, %Commit{source: source} = commit) do
    if is_list(sources) and source not in sources do
      {:skip, "only checked on #{Enum.map_join(sources, "/", &inspect/1)} change sets"}
    else
      check(rule, commit)
    end
  end

  defp check(%__MODULE__{check: check, opts: opts}, commit) do
    result =
      case check do
        f when is_function(f, 1) -> f.(commit)
        f when is_function(f, 2) -> f.(commit, opts)
      end

    case result do
      {:skip, reason} when is_binary(reason) -> {:skip, reason}
      _ -> :pass
    end
  rescue
    e in Violation ->
      {:fail, e.message}

    _ in NoMessageError ->
      {:skip, "needs a commit message; the change set was built from #{inspect(commit.source)}"}

    e ->
      {:error, e, __STACKTRACE__}
  end
end
