defmodule AssertCommit.RuleSet do
  @moduledoc """
  A module that groups related rules, so a configuration can enable a whole
  area of policy with one entry.

      defmodule MyApp.CommitRules do
        use AssertCommit.RuleSet

        import AssertCommit.Query
        import AssertCommit.Assertions

        rule :no_todo, "no TODO without an issue reference", fn commit ->
          refute_added_lines(commit, ~r/TODO(?!\\(#\\d+\\))/, in: ~r{^lib/})
        end

        rule :subject, "subject matches the configured pattern", fn commit, opts ->
          assert_subject(commit, Keyword.fetch!(opts, :subject))
        end
      end

  In `.assert_commit.exs` a rule set is named by module, optionally with
  `only:`/`except:` to select rules and any other options the rules read:

      [
        AssertCommit.Rules.Phoenix,
        {AssertCommit.Rules.Ecto, except: [:migrations_reversible]},
        {MyApp.CommitRules, subject: ~r/^\\[\\w+\\] /}
      ]
  """

  alias AssertCommit.Rule

  @doc "The rules in the set, configured with `opts`."
  @callback rules(keyword()) :: [Rule.t()]

  @doc "A one-line description of the set, for `mix assert_commit --list`."
  @callback description() :: String.t()

  @typedoc "A rule set as it appears in configuration."
  @type spec :: module() | {module(), keyword()}

  defmacro __using__(opts) do
    quote do
      @behaviour AssertCommit.RuleSet
      @before_compile AssertCommit.RuleSet
      @assert_commit_description unquote(Keyword.get(opts, :description))
      Module.register_attribute(__MODULE__, :assert_commit_rules, accumulate: true)
      import AssertCommit.RuleSet, only: [rule: 3]
    end
  end

  @doc """
  Declares a rule. `check` is a function of the commit, or of the commit and
  the set's options.
  """
  defmacro rule(id, name, check) do
    quote do
      @assert_commit_rules unquote(id)
      @doc false
      def __rule__(unquote(id)), do: {unquote(name), unquote(check)}
    end
  end

  defmacro __before_compile__(env) do
    description =
      Module.get_attribute(env.module, :assert_commit_description) ||
        first_line(Module.get_attribute(env.module, :moduledoc))

    quote do
      @impl true
      def description, do: unquote(description)

      @impl true
      def rules(opts \\ []) do
        for id <- Enum.reverse(@assert_commit_rules) do
          {name, check} = __rule__(id)
          Rule.new(id, name, check, set: __MODULE__, opts: opts)
        end
      end
    end
  end

  defp first_line({_line, doc}) when is_binary(doc),
    do: doc |> String.split("\n", parts: 2) |> hd() |> String.trim()

  defp first_line(_), do: ""

  @doc """
  Expands a configuration entry into rules, applying `only:` and `except:`
  and passing the remaining options to the set.
  """
  @spec expand(spec()) :: [Rule.t()]
  def expand(module) when is_atom(module), do: expand({module, []})

  def expand({module, opts}) when is_atom(module) and is_list(opts) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :rules, 1) do
      raise ArgumentError,
            "#{inspect(module)} is not a rule set (it does not `use AssertCommit.RuleSet`)"
    end

    {only, opts} = Keyword.pop(opts, :only)
    {except, opts} = Keyword.pop(opts, :except, [])
    rules = module.rules(opts)
    known = Enum.map(rules, & &1.id)

    for id <- List.wrap(only) ++ except, id not in known do
      raise ArgumentError,
            "#{inspect(module)} has no rule #{inspect(id)}; it has #{inspect(known)}"
    end

    rules
    |> Enum.filter(&(is_nil(only) or &1.id in only))
    |> Enum.reject(&(&1.id in except))
  end
end
