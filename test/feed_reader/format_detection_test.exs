defmodule FeedReader.FormatDetectionTest do
  use ExUnit.Case, async: true

  alias FeedReader.TestSupport.ExternalFormat

  test "detects RSS, Atom, and RDF from a bounded XML prefix" do
    assert FeedReader.detect_format("<?xml version='1.0'?><rss version='2.0'>") == :rss
    assert FeedReader.detect_format("<feed xmlns='http://www.w3.org/2005/Atom'>") == :atom
    assert FeedReader.detect_format("<rdf:RDF xmlns:rdf='urn:rdf'>") == :rdf
    assert FeedReader.detect_format("<html><body>not a feed</body></html>") == :unknown
  end

  test "custom format detection replays the bounded prefix and unread chunks" do
    chunks = ["<external-feed>tail", "continued"]

    {format, _prefix, replay} =
      FeedReader.FormatDetector.detect_and_replay(chunks,
        formats: [ExternalFormat],
        max_detection_bytes: 15
      )

    assert format == :external_test
    assert replay |> Enum.to_list() |> IO.iodata_to_binary() == IO.iodata_to_binary(chunks)
    assert FeedReader.detect_format("<feed><rss version='2.0'>") == :rss
  end

  test "detection does not inspect content beyond the configured prefix" do
    content = String.duplicate("x", 12) <> "<rss version='2.0'>"

    assert FeedReader.detect_format(content, max_detection_bytes: 12) == :unknown
    assert FeedReader.detect_format(content, max_detection_bytes: 40) == :rss
  end

  test "validation checks only the explicitly selected format" do
    rss = "<rss version='2.0'><channel></channel></rss>"

    assert FeedReader.validate(rss, :rss)
    assert FeedReader.validate(rss, FeedReader.Formats.RSS)
    refute FeedReader.validate(rss, :atom)
    refute FeedReader.validate(rss, :unknown)
    assert FeedReader.validate("<external-feed>", ExternalFormat)
  end
end
