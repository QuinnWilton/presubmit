defmodule AssertCommit.Config do
  @moduledoc """
  Loads the rule configuration from `.assert_commit.exs`.

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

  Without a file, `default/0` enables every built-in set with its defaults.
  """

  alias AssertCommit.{Rule, Rules, RuleSet}

  defmodule Error do
    @moduledoc "Raised when the configuration file is missing, invalid, or names unknown rules."
    defexception [:message]
  end

  @enforce_keys [:sets, :rules]
  defstruct [:sets, :rules, path: nil]

  @type t :: %__MODULE__{sets: [RuleSet.spec()], rules: [Rule.t()], path: Path.t() | nil}

  @default_file ".assert_commit.exs"

  @default_sets [
    Rules.Elixir,
    Rules.Phoenix,
    Rules.Ecto,
    Rules.OTP,
    Rules.ExUnit,
    Rules.Mix,
    Rules.Changelog,
    Rules.Message,
    Rules.Hygiene,
    Rules.Shape
  ]

  @doc "Every built-in rule set."
  @spec builtin_sets() :: [module()]
  def builtin_sets, do: @default_sets

  @doc "The configuration used when no file is present: every built-in set with defaults."
  @spec default() :: t()
  def default, do: from_specs(@default_sets, nil)

  @doc """
  Loads `path` (default `.assert_commit.exs` under `opts[:repo]`), falling
  back to `default/0` when the default file does not exist. An explicitly
  named file that does not exist is an error.
  """
  @spec load!(keyword()) :: t()
  def load!(opts \\ []) do
    repo = Keyword.get(opts, :repo, File.cwd!())

    case Keyword.get(opts, :config) do
      nil ->
        path = Path.join(repo, @default_file)
        if File.exists?(path), do: from_file(path), else: default()

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
