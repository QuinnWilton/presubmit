defmodule AssertCommit.MessageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AssertCommit.Message

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

  describe "properties" do
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
