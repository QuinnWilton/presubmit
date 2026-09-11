# credo:disable-for-this-file Credo.Check.Consistency.ExceptionNames
# A violation is a rule finding, not a program error, so it does not take the Error suffix.
defmodule AssertCommit.Violation do
  @moduledoc """
  Raised by an assertion verb when a change set does not satisfy it.

  The message names the offending paths, modules, or lines and says what
  would satisfy the verb; rule runners catch it and report it as a failure.
  """

  defexception [:message]

  @type t :: %__MODULE__{message: String.t()}
end
