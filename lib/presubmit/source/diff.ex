defmodule Presubmit.Source.Diff do
  @moduledoc """
  The structural difference between the Elixir source before and after a
  change set: modules and functions added, removed, renamed, or changed.

  Computed by set difference over `Presubmit.Source.Facts` for every
  changed `.ex`/`.exs` file. A module that disappears under one name and
  reappears under another with the same public functions is reported as a
  rename rather than a removal plus an addition.
  """

  alias Presubmit.{Commit, FileChange}
  alias Presubmit.Source.Facts
  alias Presubmit.Source.Facts.{Function, Module}

  defstruct modules: %{added: [], removed: [], renamed: [], modified: []},
            functions: %{
              added: [],
              removed: [],
              body_changed: [],
              spec_added: [],
              spec_removed: []
            },
            structs: %{fields_added: [], fields_removed: []},
            unparsed: []

  @type module_pair :: {Module.t(), Module.t()}

  @type t :: %__MODULE__{
          modules: %{
            added: [Module.t()],
            removed: [Module.t()],
            renamed: [module_pair()],
            modified: [module_pair()]
          },
          functions: %{
            added: [Function.t()],
            removed: [Function.t()],
            body_changed: [{Function.t(), Function.t()}],
            spec_added: [Function.t()],
            spec_removed: [Function.t()]
          },
          structs: %{fields_added: [{module(), atom()}], fields_removed: [{module(), atom()}]},
          unparsed: [{String.t(), term()}]
        }

  @doc "Computes the structural diff for every Elixir file changed by `commit`."
  @spec compute(Commit.t()) :: t()
  def compute(%Commit{changes: changes, before: before, after: after_tree}) do
    elixir = Enum.filter(changes, &(not &1.binary? and Path.extname(&1.path) in [".ex", ".exs"]))

    {before_mods, after_mods, unparsed} =
      Enum.reduce(elixir, {[], [], []}, fn change, {b, a, u} ->
        {b_mods, u} = facts(before, FileChange.before_path(change), u)
        {a_mods, u} = facts(after_tree, FileChange.after_path(change), u)
        {b ++ b_mods, a ++ a_mods, u}
      end)

    before_by_name = Map.new(before_mods, &{&1.name, &1})
    after_by_name = Map.new(after_mods, &{&1.name, &1})

    removed = for m <- before_mods, not Map.has_key?(after_by_name, m.name), do: m
    added = for m <- after_mods, not Map.has_key?(before_by_name, m.name), do: m
    modified = for m <- after_mods, b = before_by_name[m.name], b.body != m.body, do: {b, m}

    file_renames =
      for %FileChange{status: :renamed, old_path: old, path: new} <- changes, do: {old, new}

    {renamed, removed, added} = detect_renames(removed, added, file_renames)
    pairs = modified ++ renamed

    %__MODULE__{
      modules: %{added: added, removed: removed, renamed: renamed, modified: modified},
      functions: function_diff(pairs, added, removed),
      structs: struct_diff(pairs, added, removed),
      unparsed: Enum.reverse(unparsed)
    }
  end

  defp facts(_tree, nil, unparsed), do: {[], unparsed}

  defp facts(tree, path, unparsed) do
    case Facts.extract(tree, path) do
      {:ok, %Facts{modules: modules}} -> {modules, unparsed}
      {:error, reason} -> {[], [{path, reason} | unparsed]}
    end
  end

  # A removed and an added module are one rename when their surfaces (public functions and
  # struct fields) match and are non-trivial, or when git renamed the file between them.
  defp detect_renames(removed, added, file_renames) do
    Enum.reduce(removed, {[], [], added}, fn old, {renamed, still_removed, remaining} ->
      match =
        Enum.find(remaining, fn new ->
          surface(new) == surface(old) and
            (surface(old) != {[], []} or {old.path, new.path} in file_renames)
        end)

      case match do
        %Module{} = new -> {[{old, new} | renamed], still_removed, List.delete(remaining, new)}
        nil -> {renamed, [old | still_removed], remaining}
      end
    end)
    |> then(fn {renamed, still_removed, remaining} ->
      {Enum.reverse(renamed), Enum.reverse(still_removed), remaining}
    end)
  end

  defp surface(%Module{} = m) do
    {m |> Module.public_functions() |> Enum.map(&{&1.name, &1.arity}) |> Enum.sort(),
     struct_fields(m)}
  end

  # Functions are keyed by name/arity within a module pair; across a rename the module differs,
  # so keys are compared by name/arity only.
  defp function_diff(pairs, added_mods, removed_mods) do
    base = %{added: [], removed: [], body_changed: [], spec_added: [], spec_removed: []}

    diffed =
      Enum.reduce(pairs, base, fn {old, new}, acc ->
        old_fns = Map.new(old.functions, &{{&1.name, &1.arity}, &1})
        new_fns = Map.new(new.functions, &{{&1.name, &1.arity}, &1})

        %{
          acc
          | added: acc.added ++ for({k, f} <- new_fns, not Map.has_key?(old_fns, k), do: f),
            removed: acc.removed ++ for({k, f} <- old_fns, not Map.has_key?(new_fns, k), do: f),
            body_changed:
              acc.body_changed ++
                for({k, f} <- new_fns, o = old_fns[k], o.clauses != f.clauses, do: {o, f}),
            spec_added:
              acc.spec_added ++
                for({k, f} <- new_fns, o = old_fns[k], f.spec? and not o.spec?, do: f),
            spec_removed:
              acc.spec_removed ++
                for({k, f} <- new_fns, o = old_fns[k], o.spec? and not f.spec?, do: f)
        }
      end)

    %{
      diffed
      | added: sort(diffed.added ++ Enum.flat_map(added_mods, & &1.functions)),
        removed: sort(diffed.removed ++ Enum.flat_map(removed_mods, & &1.functions)),
        body_changed: Enum.sort_by(diffed.body_changed, fn {_, f} -> Function.key(f) end),
        spec_added: sort(diffed.spec_added),
        spec_removed: sort(diffed.spec_removed)
    }
  end

  defp sort(functions), do: Enum.sort_by(functions, &Function.key/1)

  defp struct_diff(pairs, added_mods, removed_mods) do
    from_pairs =
      Enum.reduce(pairs, {[], []}, fn {old, new}, {added, removed} ->
        old_fields = struct_fields(old)
        new_fields = struct_fields(new)

        {added ++ for(f <- new_fields -- old_fields, do: {new.name, f}),
         removed ++ for(f <- old_fields -- new_fields, do: {old.name, f})}
      end)

    {added, removed} = from_pairs

    %{
      fields_added:
        Enum.sort(added ++ for(m <- added_mods, f <- struct_fields(m), do: {m.name, f})),
      fields_removed:
        Enum.sort(removed ++ for(m <- removed_mods, f <- struct_fields(m), do: {m.name, f}))
    }
  end

  defp struct_fields(%Module{struct: nil}), do: []
  defp struct_fields(%Module{struct: %{fields: fields}}), do: fields

  @doc "API functions (public, not `@doc false`) added, as `{module, name, arity}`."
  @spec public_added(t()) :: [{module(), atom(), arity()}]
  def public_added(%__MODULE__{functions: %{added: added}}),
    do: added |> Enum.filter(&Function.api?/1) |> Enum.map(&Function.key/1)

  @doc "API functions (public, not `@doc false`) removed, as `{module, name, arity}`."
  @spec public_removed(t()) :: [{module(), atom(), arity()}]
  def public_removed(%__MODULE__{functions: %{removed: removed}}),
    do: removed |> Enum.filter(&Function.api?/1) |> Enum.map(&Function.key/1)

  @doc "Whether any API function was added or removed."
  @spec public_api_changed?(t()) :: boolean()
  def public_api_changed?(diff), do: public_added(diff) != [] or public_removed(diff) != []

  @doc "Whether any function body changed, or any function was added or removed."
  @spec behaviour_changed?(t()) :: boolean()
  def behaviour_changed?(%__MODULE__{functions: f}),
    do: f.added != [] or f.removed != [] or f.body_changed != []
end
