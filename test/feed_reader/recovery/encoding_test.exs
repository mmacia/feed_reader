defmodule FeedReader.Recovery.EncodingTest do
  use ExUnit.Case, async: true

  alias FeedReader.Recovery.Encoding
  alias FeedReader.Recovery

  test "passes UTF-8 input through unchanged" do
    chunks = ["<title>", "café", "</title>"]

    assert Encoding.transcode(chunks, :utf8) == chunks
    assert Encoding.normalize_declaration(chunks, :utf8) == chunks
  end

  test "transcodes Latin-1 chunks to UTF-8" do
    chunks = ["<title>caf", <<0xE9>>, "</title>"]

    assert chunks |> Encoding.transcode(:latin1) |> Enum.join() == "<title>café</title>"
  end

  test "rewrites a Latin-1 declaration to UTF-8" do
    chunks = ["<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>", "<rss/>"]

    assert chunks |> Encoding.normalize_declaration(:latin1) |> Enum.join() ==
             "<?xml version=\"1.0\" encoding=\"UTF-8\"?><rss/>"
  end

  test "rewrites declarations split across chunks" do
    chunks = ["<?xml version=\"1.0\" enc", "oding=\"latin1\"?>", "<rss/>"]

    assert chunks |> Encoding.normalize_declaration(:latin1) |> Enum.join() ==
             "<?xml version=\"1.0\" encoding=\"UTF-8\"?><rss/>"
  end

  test "rewrites a US-ASCII declaration to UTF-8" do
    chunks = ["<?xml version=\"1.0\" encoding=\"us-ascii\"?>", "<rss/>"]

    assert chunks |> Encoding.normalize_declaration(:ascii) |> Enum.join() ==
             "<?xml version=\"1.0\" encoding=\"UTF-8\"?><rss/>"
  end

  test "recognizes US-ASCII declarations" do
    assert Recovery.declared_encoding("<?xml encoding=\"us-ascii\"?>") == :ascii
  end
end
