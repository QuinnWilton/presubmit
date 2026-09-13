defmodule AssertCommit.Config do
  @moduledoc """
  Loads the rule configuration from `.assert_commit.exs`, or builds a
  default one from what the examined tree and the VM contain.

  The file evaluates to a list of rule-set specs (see `AssertCommit.RuleSet`):

      [
        AssertCommit.Rules.Elixir,
        AssertCommit.Rules.Phoenix,
        {AssertCommit.Rules.Ecto, except: [:migrations_reversible]},
        {AssertCommit.Rules.Message, subject: ~r/^\\[[a-z_-]+\\] /},
        MyApp.CommitRules
      ]

  A project-specific rule set can be defined inline in the file with
  `defmodule`, or loaded from another file with `Code.require_file/1`.

  ## Defaults

  Without a file, `default/1` enables the sets that apply to the project:
  always `Elixir`, `Hygiene`, `Mix`, `OTP`, `Shape`, the message basics
  (`no_fixup`, `subject_length`), and `ExUnit`'s `behaviour_changes_tested`;
  `Phoenix` and `Ecto` when those libraries are loaded in the VM or declared
  in the examined tree's `mix.exs`; `Changelog` when the tree has a
  `CHANGELOG.md`. Each set's `requires/0` states the condition, and
  `t:t/0`'s `:detection` records what was decided and why.
  """

  alias AssertCommit.{Commit, MixFile, Rule, Rules, RuleSet, Tree}

  defmodule Error do
    @moduledoc "Raised when the configuration file is missing, invalid, or names unknown rules."
    defexception [:message]
  end

  @enforce_keys [:sets, :rules]
  defstruct [:sets, :rules, path: nil, detection: []]

  @typedoc "For each candidate default set, whether it was enabled and the reasons."
  @type detection :: [{module(), :enabled | :disabled, [String.t()]}]

  @type t :: %__MODULE__{
          sets: [RuleSet.spec()],
          rules: [Rule.t()],
          path: Path.t() | nil,
          detection: detection()
        }

  @default_file ".assert_commit.exs"

  @default_specs [
    Rules.Elixir,
    Rules.Phoenix,
    Rules.Ecto,
    Rules.OTP,
    {Rules.ExUnit, only: [:behaviour_changes_tested]},
    Rules.Mix,
    Rules.Changelog,
    {Rules.Message, only: [:no_fixup, :subject_length]},
    Rules.Hygiene,
    Rules.Shape
  ]

  @doc "Every built-in rule set."
  @spec builtin_sets() :: [module()]
  def builtin_sets, do: Enum.map(@default_specs, &spec_module/1)

  @doc """
  The default configuration for a change set: every built-in default spec
  whose requirements hold (see the module documentation).

  Pass `commit:` (or `tree:`) so dependencies and files can be read from the
  examined tree; pass `loaded?:` to override the VM check (tests).
  """
  @spec default(keyword()) :: t()
  def default(opts \\ []) do
    env = env(opts)

    detection =
      Enum.map(@default_specs, fn spec ->
        module = spec_module(spec)

        case RuleSet.applicable?(module, env) do
          {:ok, reasons} -> {module, :enabled, reasons}
          {:missing, reasons} -> {module, :disabled, reasons}
        end
      end)

    enabled = for {module, :enabled, _} <- detection, into: MapSet.new(), do: module
    specs = Enum.filter(@default_specs, &MapSet.member?(enabled, spec_module(&1)))

    %{from_specs(specs, nil) | detection: detection}
  end

  @doc """
  Loads `path` (default `.assert_commit.exs` under `opts[:repo]`), falling
  back to `default/1` when the default file does not exist. An explicitly
  named file that does not exist is an error. `commit:` feeds detection.
  """
  @spec load!(keyword()) :: t()
  def load!(opts \\ []) do
    repo = Keyword.get(opts, :repo, File.cwd!())

    case Keyword.get(opts, :config) do
      nil ->
        path = Path.join(repo, @default_file)
        if File.exists?(path), do: from_file(path), else: default(opts)

      path ->
        path = Path.expand(path, repo)

        if File.exists?(path),
          do: from_file(path),
          else: raise(Error, message: "configuration file #{path} does not exist")
    end
  end

  @doc "Builds a configuration from rule-set specs."
  @spec from_specs([RuleSet.spec()], Path.t() | nil) :: t()
  def from_specs(specs, path \\ nil) when is_list(specs) do
    rules = Enum.flat_map(specs, &expand(&1, path))
    %__MODULE__{sets: specs, rules: rules, path: path}
  end

  @doc "The detection environment for a change set: loaded modules, declared deps, files."
  @spec env(keyword()) :: RuleSet.env()
  def env(opts \\ []) do
    tree =
      case {Keyword.get(opts, :commit), Keyword.get(opts, :tree)} do
        {%Commit{after: tree}, _} -> tree
        {_, %Tree{} = tree} -> tree
        _ -> nil
      end

    deps =
      if tree,
        do: Enum.uniq(Enum.map(MixFile.all_deps(tree), & &1.name) ++ MixFile.all_locked(tree)),
        else: []

    # A required file counts at the root or at the root of any nested project.
    file? = fn path ->
      tree != nil and
        (Tree.exists?(tree, path) or
           Enum.any?(Tree.paths(tree), &String.ends_with?(&1, "/" <> path)))
    end

    %{loaded?: Keyword.get(opts, :loaded?, &Code.ensure_loaded?/1), deps: deps, file?: file?}
  end

  defp spec_module(module) when is_atom(module), do: module
  defp spec_module({module, _opts}), do: module

  defp expand(spec, path) do
    RuleSet.expand(spec)
  rescue
    e in ArgumentError ->
      reraise Error,
              [message: "#{path || "configuration"}: #{Exception.message(e)}"],
              __STACKTRACE__
  end

  defp from_file(path) do
    {value, _binding} = Code.eval_file(path)

    case value do
      specs when is_list(specs) ->
        from_specs(specs, path)

      other ->
        raise Error,
          message:
            "#{path} must evaluate to a list of rule sets, but evaluated to #{inspect(other, limit: 5)}"
    end
  end
end
