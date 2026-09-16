defmodule Presubmit.Message do
  @moduledoc """
  A parsed commit message: subject, body, and trailers.

  Trailers are `Key: value` lines in the final paragraph of the message,
  following git's own `interpret-trailers` conventions closely enough for
  `Co-Authored-By`, `Signed-off-by`, `BREAKING CHANGE`, and custom keys.
  """

  @enforce_keys [:raw, :subject, :body, :trailers]
  defstruct [:raw, :subject, :body, :trailers]

  @type trailer :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          raw: String.t(),
          subject: String.t(),
          body: String.t(),
          trailers: [trailer()]
        }

  @trailer_line ~r/^([A-Za-z][A-Za-z0-9 -]*?)\s*:\s+(.+?)\s*$/

  @doc """
  Parses a raw commit message.

  The subject is the first paragraph joined onto one line (git folds
  multi-line subjects the same way); the body is everything between the
  subject and the trailer block.
  """
  @spec parse(String.t()) :: t()
  def parse(raw) when is_binary(raw) do
    paragraphs =
      raw
      |> String.replace("\r\n", "\n")
      |> String.trim()
      |> String.split(~r/\n{2,}/)

    {subject, rest} =
      case paragraphs do
        [] -> {"", []}
        [first | rest] -> {first |> String.split("\n") |> Enum.join(" "), rest}
      end

    {body_paragraphs, trailers} = split_trailers(rest)

    %__MODULE__{
      raw: raw,
      subject: subject,
      body: Enum.join(body_paragraphs, "\n\n"),
      trailers: trailers
    }
  end

  @doc """
  Applies git's default message cleanup to text from a `commit-msg` hook or
  editor: comment lines are dropped, everything from a scissors line on is
  dropped, and surrounding whitespace is trimmed.
  """
  @spec clean(String.t()) :: String.t()
  def clean(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.take_while(
      &(not String.starts_with?(&1, "# ------------------------ >8 ------------------------"))
    )
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.join("\n")
    |> String.trim()
  end

  @doc """
  Every value for the trailer `key`, compared case-insensitively.
  """
  @spec trailer_values(t(), String.t()) :: [String.t()]
  def trailer_values(%__MODULE__{trailers: trailers}, key) do
    wanted = String.downcase(key)
    for {k, v} <- trailers, String.downcase(k) == wanted, do: v
  end

  # The final paragraph is a trailer block only if every line parses as a trailer.
  defp split_trailers([]), do: {[], []}

  defp split_trailers(paragraphs) do
    {body, [last]} = Enum.split(paragraphs, -1)
    lines = String.split(last, "\n")

    parsed = Enum.map(lines, &Regex.run(@trailer_line, &1, capture: :all_but_first))

    if Enum.all?(parsed, &match?([_, _], &1)) do
      {body, Enum.map(parsed, fn [k, v] -> {k, v} end)}
    else
      {paragraphs, []}
    end
  end
end
