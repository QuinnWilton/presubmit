defmodule AssertCommit.JSON do
  @moduledoc false
  # A minimal encoder so the JSON report needs no runtime dependency.

  @spec encode(term()) :: iodata()
  def encode(nil), do: "null"
  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(atom) when is_atom(atom), do: encode(Atom.to_string(atom))
  def encode(n) when is_integer(n), do: Integer.to_string(n)
  def encode(f) when is_float(f), do: Float.to_string(f)
  def encode(s) when is_binary(s), do: [?", escape(s), ?"]
  def encode(list) when is_list(list), do: [?[, Enum.map_intersperse(list, ?,, &encode/1), ?]]

  def encode(%{} = map) do
    [
      ?{,
      Enum.map_intersperse(map, ?,, fn {k, v} -> [encode(to_string(k)), ?:, encode(v)] end),
      ?}
    ]
  end

  def encode(other), do: encode(inspect(other))

  defp escape(s) do
    for <<c <- s>>, into: "" do
      case c do
        ?" -> "\\\""
        ?\\ -> "\\\\"
        ?\n -> "\\n"
        ?\r -> "\\r"
        ?\t -> "\\t"
        c when c < 0x20 -> "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")
        c -> <<c>>
      end
    end
  end
end
