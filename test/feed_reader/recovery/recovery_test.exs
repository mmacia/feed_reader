defmodule FeedReader.RecoveryTest do
  use ExUnit.Case, async: true

  alias FeedReader.Recovery

  describe "declared_encoding/1" do
    test "defaults to UTF-8 when no declaration is present" do
      assert Recovery.declared_encoding("<rss/>") == :utf8
    end

    test "recognizes common Latin-1 aliases case-insensitively" do
      assert Recovery.declared_encoding(~s(<?xml encoding="ISO-8859-1"?>)) == :latin1
      assert Recovery.declared_encoding(~s(<?xml encoding='LaTiN-1'?>)) == :latin1
    end

    test "recognizes US-ASCII and leaves other declarations UTF-8" do
      assert Recovery.declared_encoding(~s(<?xml encoding="US-ASCII"?>)) == :ascii
      assert Recovery.declared_encoding(~s(<?xml encoding="UTF-8"?>)) == :utf8
      assert Recovery.declared_encoding(~s(<?xml encoding="UTF-16"?>)) == :utf8
    end

    test "finds declarations after XML declaration attributes" do
      prefix = ~s(<?xml version="1.0" standalone="yes" encoding = 'latin-1'?>)

      assert Recovery.declared_encoding(prefix) == :latin1
    end
  end

  test "normalizes all recovery stages across chunk boundaries" do
    chunks = [
      <<0xEF>>,
      <<0xBB, 0xBF>>,
      " \n<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>",
      ~s(<item title="A "quoted"">caf),
      <<0xE9>>,
      " & B</item>"
    ]

    assert normalize(chunks, :latin1) ==
             ~s(<?xml version="1.0" encoding="UTF-8"?><item title="A &quot;quoted&quot;">café &amp; B</item>)
  end

  test "preserves CDATA and comments while repairing surrounding text" do
    chunks = [
      "<root><![C",
      "DATA[A & B]]><!-- C & D -->E & F</root>"
    ]

    assert normalize(chunks, :utf8) ==
             "<root><![CDATA[A & B]]><!-- C & D -->E &amp; F</root>"
  end

  defp normalize(chunks, encoding), do: chunks |> Recovery.normalize(encoding) |> Enum.join()
end
