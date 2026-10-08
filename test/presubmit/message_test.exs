defmodule Presubmit.MessageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Presubmit.Message

  describe "parse/1" do
    test "subject only" do
      assert %Message{subject: "Fix it", body: "", trailers: []} = Message.parse("Fix it\n")
    end

    test "folds a wrapped subject onto one line, as git does" do
      assert Message.parse("Fix the\nthing").subject == "Fix the thing"
    end

    test "separates body from trailers" do
      msg =
        Message.parse(
          "Subject\n\nBody para one.\n\nBody para two.\n\nSigned-off-by: A <a@x>\nCo-Authored-By: B <b@x>\n"
        )

      assert msg.body == "Body para one.\n\nBody para two."
      assert msg.trailers == [{"Signed-off-by", "A <a@x>"}, {"Co-Authored-By", "B <b@x>"}]
    end

    test "a final paragraph with any non-trailer line is body, not trailers" do
      msg = Message.parse("Subject\n\nKey: value\nnot a trailer\n")
      assert msg.trailers == []
      assert msg.body == "Key: value\nnot a trailer"
    end

    test "BREAKING CHANGE with a space is a valid key" do
      assert Message.trailer_values(
               Message.parse("S\n\nBREAKING CHANGE: gone"),
               "breaking change"
             ) == ["gone"]
    end

    test "URLs in the subject are not trailers" do
      assert Message.parse("See https://example.com: details").trailers == []
    end

    test "trailer keys are matched case-insensitively" do
      msg = Message.parse("S\n\nco-authored-by: X")
      assert Message.trailer_values(msg, "Co-Authored-By") == ["X"]
    end

    test "CRLF messages parse the same as LF" do
      crlf = Message.parse("S\r\n\r\nK: v\r\n")
      lf = Message.parse("S\n\nK: v\n")
      assert Map.delete(crlf, :raw) == Map.delete(lf, :raw)
    end
  end

  describe "autosquash/1" do
    test "reads git's autosquash prefixes from the subject" do
      assert Message.autosquash(Message.parse("fixup! [argus] return a finding")) == :fixup
      assert Message.autosquash(Message.parse("squash! Fix it\n\nMore.\n")) == :squash
      assert Message.autosquash(Message.parse("amend! Fix it\n\nFix it properly\n")) == :amend
      assert Message.autosquash(Message.parse("fixup! fixup! Fix it")) == :fixup
    end

    test "is nil for any other subject, including a prefix git would not fold" do
      assert Message.autosquash(Message.parse("Fix it")) == nil
      assert Message.autosquash(Message.parse("fixup!Fix it")) == nil
      assert Message.autosquash(Message.parse("Fixup! Fix it")) == nil
      assert Message.autosquash(Message.parse("[fixup] Fix it")) == nil
      assert Message.autosquash(Message.parse("Fix it\n\nfixup! not the subject\n")) == nil
    end
  end

  describe "body_lines/1" do
    test "numbers the body's lines as they appear in the message" do
      raw = "Subject\nwrapped\n\n\nOne.\nTwo.\n\nThree.\n\nSigned-off-by: A <a@x>\n"
      assert Message.body_lines(Message.parse(raw)) == [{5, "One."}, {6, "Two."}, {8, "Three."}]
    end

    test "keeps a final paragraph that is not a trailer block" do
      assert Message.body_lines(Message.parse("S\n\nKey: value\nnot a trailer")) ==
               [{3, "Key: value"}, {4, "not a trailer"}]
    end

    test "counts leading blank lines and CRLF line endings" do
      assert Message.body_lines(Message.parse("\n  \nS\r\n\r\nBody\r\n")) == [{5, "Body"}]
    end

    test "is empty without a body" do
      assert Message.body_lines(Message.parse("S\n")) == []
      assert Message.body_lines(Message.parse("S\n\nK: v\n")) == []
      assert Message.body_lines(Message.parse("")) == []
    end
  end

  describe "clean/1" do
    test "drops comment lines and everything after a scissors line, then trims" do
      raw = """
      [x] subject

      Body.
      # Please enter the commit message for your changes. Lines starting
      # with '#' will be ignored, and an empty message aborts the commit.
      #
      # On branch main
      Trailer: v
      # ------------------------ >8 ------------------------
      diff --git a/x b/x
      """

      assert Message.clean(raw) == "[x] subject\n\nBody.\nTrailer: v"
      assert Message.parse(Message.clean(raw)).trailers == []
    end

    test "leaves an already clean message alone" do
      assert Message.clean("S\n\nK: v\n") == "S\n\nK: v"
    end
  end

  describe "properties" do
    property "body lines are the parsed body's lines, numbered as in the raw message" do
      line = string([?a..?z, ?\s, ?:, ?é], min_length: 1, max_length: 20)
      paragraph = list_of(line, min_length: 1, max_length: 4) |> map(&Enum.join(&1, "\n"))
      separator = string([?\n], min_length: 2, max_length: 3)

      check all(
              subject <- string(?a..?z, min_length: 1),
              paragraphs <- list_of({separator, paragraph}, max_length: 4)
            ) do
        raw = subject <> Enum.map_join(paragraphs, fn {sep, text} -> sep <> text end)
        message = Message.parse(raw)
        lines = Message.body_lines(message)
        raw_lines = String.split(raw, "\n")

        for {number, text} <- lines, do: assert(Enum.at(raw_lines, number - 1) == text)

        # `parse/1` trims the message, so the last line's trailing whitespace may differ.
        assert Enum.map(lines, fn {_, text} -> String.trim(text) end) ==
                 message.body
                 |> String.split("\n")
                 |> Enum.reject(&(&1 == ""))
                 |> Enum.map(&String.trim/1)
      end
    end

    property "trailers round-trip through a rendered message" do
      key = string(?a..?z, min_length: 1) |> map(&String.capitalize/1)
      value = string(:alphanumeric, min_length: 1)

      check all(
              subject <- string(:alphanumeric, min_length: 1),
              trailers <- list_of({key, value}, min_length: 1, max_length: 5)
            ) do
        raw =
          subject <>
            "\n\n" <> Enum.map_join(trailers, "\n", fn {k, v} -> "#{k}: #{v}" end) <> "\n"

        assert Message.parse(raw).trailers == trailers
        assert Message.parse(raw).subject == subject
      end
    end
  end
end
