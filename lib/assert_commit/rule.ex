defmodule AssertCommit.Rule do
  @moduledoc """
  One named check over a change set.

  `check` is a function of the commit (and, for configurable rules, the
  options the rule set was given) that returns `:ok` or raises
  `AssertCommit.Violation`. Rules are grouped into rule sets
  (`AssertCommit.RuleSet`) and run by `AssertCommit.Runner`.
  """

  alias AssertCommit.{Commit, NoMessageError, Violation}

  @enforce_keys [:id, :name, :check]
  defstruct [:id, :name, :check, set: nil, opts: []]

  @type check ::
          (Commit.t() -> :ok | {:skip, String.t()})
          | (Commit.t(), keyword() -> :ok | {:skip, String.t()})

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          check: check(),
          set: module() | nil,
          opts: keyword()
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

  A `AssertCommit.Violation` is a failure; a `AssertCommit.NoMessageError`
  (a message rule run against the index or working tree) is a skip, as is a
  check returning `{:skip, reason}` (a rule whose option is not configured);
  any other exception is reported as an error rather than crashing the run.
  """
  @spec run(t(), Commit.t()) :: outcome()
  def run(%__MODULE__{check: check, opts: opts}, %Commit{} = commit) do
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
