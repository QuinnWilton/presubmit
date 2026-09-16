defmodule Presubmit.RuleSet do
  @moduledoc """
  A module that groups related rules, so a configuration can enable a whole
  area of policy with one entry.

      defmodule MyApp.CommitRules do
        use Presubmit.RuleSet

        import Presubmit.Query
        import Presubmit.Assertions

        rule :no_todo, "no TODO without an issue reference", fn commit ->
          refute_added_lines(commit, ~r/TODO(?!\\(#\\d+\\))/, in: ~r{^lib/})
        end

        rule :subject, "subject matches the configured pattern", fn commit, opts ->
          assert_subject(commit, Keyword.fetch!(opts, :subject))
        end
      end

  In `.presubmit.exs` a rule set is named by module, optionally with
  `only:`/`except:` to select rules, `warn:` to make some of them report
  without failing, `in:` to restrict the set to changes under a path
  pattern, and any other options the rules read:

      [
        Presubmit.Rules.Phoenix,
        {Presubmit.Rules.Ecto, except: [:migrations_reversible]},
        {Presubmit.Rules.Elixir, warn: [:specs]},
        {Presubmit.Rules.ExUnit, in: ~r{^apps/core/}},
        {MyApp.CommitRules, subject: ~r/^\\[\\w+\\] /}
      ]
  """

  alias Presubmit.Rule

  @doc "The rules in the set, configured with `opts`."
  @callback rules(keyword()) :: [Rule.t()]

  @doc "A one-line description of the set, for `mix presubmit --list`."
  @callback description() :: String.t()

  @doc """
  What must be present for the set to be enabled by default. `{app, module}`
  is satisfied when `module` is loaded in the VM or `app` (any of a list) is
  declared in the examined tree's `mix.exs` or present in its `mix.lock`;
  `{:file, path}` when the tree has that file.
  """
  @callback requires() :: [requirement()]

  @typedoc "A rule set as it appears in configuration."
  @type spec :: module() | {module(), keyword()}

  @typedoc "`{app_or_apps, module}`: any of the apps declared or locked, or the module loaded."
  @type requirement :: {atom() | [atom()], module()} | {:file, Path.t()}

  @typedoc """
  What `applicable?/2` consults: which modules are loaded, which apps the
  examined tree depends on, and which files it contains.
  """
  @type env :: %{
          loaded?: (module() -> boolean()),
          deps: [atom()],
          file?: (Path.t() -> boolean())
        }

  defmacro __using__(opts) do
    quote do
      @behaviour Presubmit.RuleSet
      @before_compile Presubmit.RuleSet
      @presubmit_description unquote(Keyword.get(opts, :description))
      Module.register_attribute(__MODULE__, :presubmit_rules, accumulate: true)
      import Presubmit.RuleSet, only: [rule: 3, rule: 4]

      @impl true
      def requires, do: unquote(Keyword.get(opts, :requires, []))

      defoverridable requires: 0
    end
  end

  @doc """
  Whether every requirement of `module` is satisfied under `env`, with the
  reasons: `{:ok, reasons}` or `{:missing, reasons}`.
  """
  @spec applicable?(module(), env()) :: {:ok, [String.t()]} | {:missing, [String.t()]}
  def applicable?(module, env) do
    outcomes = Enum.map(module.requires(), &check_requirement(&1, env))

    case Enum.split_with(outcomes, &match?({:ok, _}, &1)) do
      {oks, []} -> {:ok, Enum.map(oks, &elem(&1, 1))}
      {_, missing} -> {:missing, Enum.map(missing, &elem(&1, 1))}
    end
  end

  defp check_requirement({:file, path}, env) do
    if env.file?.(path), do: {:ok, "#{path} present"}, else: {:missing, "no #{path}"}
  end

  defp check_requirement({apps, module}, env) when is_atom(module) do
    apps = List.wrap(apps)

    cond do
      env.loaded?.(module) ->
        {:ok, "#{inspect(module)} loaded"}

      app = Enum.find(apps, &(&1 in env.deps)) ->
        {:ok, "#{app} is a dependency"}

      true ->
        {:missing, "#{Enum.join(apps, "/")} not a dependency and #{inspect(module)} not loaded"}
    end
  end

  @doc """
  Declares a rule. `check` is a function of the commit, or of the commit and
  the set's options. `attrs` may give `sources:`, the change-set sources the
  rule applies to (`[:head, :rev]` for rules that only make sense on a
  commit); elsewhere it is skipped.
  """
  defmacro rule(id, name, check, attrs \\ []) do
    quote do
      @presubmit_rules {unquote(id), unquote(name), unquote(attrs)}
      @doc false
      def __rule__(unquote(id)), do: {unquote(name), unquote(check), unquote(attrs)}
    end
  end

  # Appends the set's rules to its @moduledoc, so every rule set documents itself on hexdocs.
  defmacro __before_compile__(env) do
    rules = env.module |> Module.get_attribute(:presubmit_rules) |> Enum.reverse()
    moduledoc = Module.get_attribute(env.module, :moduledoc)

    description =
      Module.get_attribute(env.module, :presubmit_description) || first_line(moduledoc)

    case moduledoc do
      {line, doc} when is_binary(doc) ->
        Module.put_attribute(env.module, :moduledoc, {line, doc <> rules_section(rules)})

      _ ->
        :ok
    end

    quote do
      @impl true
      def description, do: unquote(description)

      @impl true
      def rules(opts \\ []) do
        for {id, _name, _attrs} <- Enum.reverse(@presubmit_rules) do
          {name, check, attrs} = __rule__(id)
          Rule.new(id, name, check, [set: __MODULE__, opts: opts] ++ attrs)
        end
      end
    end
  end

  defp rules_section([]), do: ""

  defp rules_section(rules) do
    items =
      Enum.map_join(rules, "\n", fn {id, name, attrs} ->
        notes =
          Enum.reject(
            [
              if(attrs[:sources],
                do: "only on #{Enum.map_join(attrs[:sources], "/", &inspect/1)}"
              ),
              if(attrs[:severity] == :warn, do: "warns by default")
            ],
            &is_nil/1
          )

        "- `#{id}` — #{name}#{if notes == [], do: "", else: " (#{Enum.join(notes, "; ")})"}"
      end)

    "\n\n## Rules\n\n" <> items <> "\n"
  end

  defp first_line({_line, doc}) when is_binary(doc),
    do: doc |> String.split("\n", parts: 2) |> hd() |> String.trim()

  defp first_line(_), do: ""

  @doc """
  Expands a configuration entry into rules, applying `only:`, `except:`,
  `warn:`, and `in:` and passing the remaining options to the set.
  """
  @spec expand(spec()) :: [Rule.t()]
  def expand(module) when is_atom(module), do: expand({module, []})

  def expand({module, opts}) when is_atom(module) and is_list(opts) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :rules, 1) do
      raise ArgumentError,
            "#{inspect(module)} is not a rule set (it does not `use Presubmit.RuleSet`)"
    end

    {only, opts} = Keyword.pop(opts, :only)
    {except, opts} = Keyword.pop(opts, :except, [])
    {warn, opts} = Keyword.pop(opts, :warn, [])
    {scope, opts} = Keyword.pop(opts, :in)
    rules = module.rules(opts)
    known = Enum.map(rules, & &1.id)

    for id <- List.wrap(only) ++ except ++ warn, id not in known do
      raise ArgumentError,
            "#{inspect(module)} has no rule #{inspect(id)}; it has #{inspect(known)}"
    end

    rules
    |> Enum.filter(&(is_nil(only) or &1.id in only))
    |> Enum.reject(&(&1.id in except))
    |> Enum.map(fn rule ->
      %{rule | severity: if(rule.id in warn, do: :warn, else: rule.severity), scope: scope}
    end)
  end
end
