defmodule Presubmit.Rule do
  @moduledoc """
  One named check over a change set.

  `check` is a function of the commit (and, for configurable rules, the
  options the rule set was given) that returns `:ok` or raises
  `Presubmit.Violation`. Rules are grouped into rule sets
  (`Presubmit.RuleSet`) and run by `Presubmit.Runner`.

  A rule may declare the change-set `sources` it applies to; outside them it
  is skipped. `no_fixup` is the canonical case: `fixup!` commits are meant to
  exist locally and be autosquashed, so the rule applies to committed
  revisions (`:head`, `:rev`) and not to the index a hook is checking.

  A rule's `severity` is `:error` (a violation fails the run) or `:warn` (it
  is reported but does not fail). Its `scope`, when set, restricts the
  change set to files matching a pattern before the check runs, so one
  configuration can apply different rules to different parts of a repository.

  A commit may exempt itself with trailers, as in Chromium: `No-Presubmit: true`
  skips every rule, and `Presubmit-Skip: pure_move, max_files` skips the
  named ones. The exemption is part of the commit and is reported on every
  run, which is the point — unlike `git commit --no-verify`, it leaves a
  trace and CI sees the same decision.
  """

  alias Presubmit.{Commit, Message, NoMessageError, Violation}

  @enforce_keys [:id, :name, :check]
  defstruct [:id, :name, :check, set: nil, opts: [], sources: nil, severity: :error, scope: nil]

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

  A `Presubmit.Violation` is a failure. A skip is: a
  `Presubmit.NoMessageError` (a message rule against the index or working
  tree), a check returning `{:skip, reason}` (nothing configured), or a
  change set outside the rule's `sources`. Any other exception is reported
  as an error rather than crashing the run.
  """
  @spec run(t(), Commit.t()) :: outcome()
  def run(%__MODULE__{sources: sources, scope: scope} = rule, %Commit{source: source} = commit) do
    cond do
      exempted?(rule, commit) ->
        {:skip, "exempted by the commit's #{exemption_trailer(rule, commit)} trailer"}

      is_list(sources) and source not in sources ->
        {:skip, "only checked on #{Enum.map_join(sources, "/", &inspect/1)} change sets"}

      scope != nil ->
        case Commit.restrict(commit, scope) do
          %Commit{changes: []} ->
            {:skip, "no changes under #{Presubmit.Pattern.format(scope)}"}

          scoped ->
            rule |> check(scoped) |> soften(rule)
        end

      true ->
        rule |> check(commit) |> soften(rule)
    end
  end

  @doc "Rule ids a commit's `Presubmit-Skip:` trailers name, or `:all` for `No-Presubmit: true`."
  @spec exemptions(Commit.t()) :: :all | [atom()]
  def exemptions(%Commit{message: nil}), do: []

  def exemptions(%Commit{message: message}) do
    if Enum.any?(
         Message.trailer_values(message, "No-Presubmit"),
         &(String.downcase(&1) == "true")
       ) do
      :all
    else
      message
      |> Message.trailer_values("Presubmit-Skip")
      |> Enum.flat_map(&String.split(&1, ~r/[,\s]+/, trim: true))
      |> Enum.map(&String.to_atom/1)
    end
  end

  defp exempted?(%__MODULE__{id: id}, commit) do
    case exemptions(commit) do
      :all -> true
      ids -> id in ids
    end
  end

  defp exemption_trailer(_rule, commit),
    do: if(exemptions(commit) == :all, do: "No-Presubmit", else: "Presubmit-Skip")

  defp soften({:fail, message}, %__MODULE__{severity: :warn}), do: {:warn, message}
  defp soften(outcome, _rule), do: outcome

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
  catch
    # A rule that exits or throws must not take the worker (and the linked runner) down with it.
    :exit, reason ->
      {:error, %RuntimeError{message: "rule exited: #{inspect(reason)}"}, __STACKTRACE__}

    :throw, value ->
      {:error, %RuntimeError{message: "rule threw: #{inspect(value)}"}, __STACKTRACE__}
  end
end
