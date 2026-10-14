defmodule FeedReader.URLTest do
  use ExUnit.Case, async: true

  alias FeedReader.URL

  test "returns nil for a missing URL" do
    assert URL.resolve_root_relative(nil, ["https://example.com"]) == nil
  end

  test "returns absolute and other non-root-relative URLs unchanged" do
    absolute = "https://cdn.example.com/story"

    assert URL.resolve_root_relative(absolute, ["https://example.com"]) == absolute
    assert URL.resolve_root_relative("story", ["https://example.com"]) == "story"
  end

  test "resolves a root-relative URL against the first absolute base" do
    assert URL.resolve_root_relative("/story", ["relative", nil, "https://example.com/feed"]) ==
             "https://example.com/story"
  end

  test "keeps a root-relative URL when no absolute base exists" do
    assert URL.resolve_root_relative("/story", [nil, "relative", 123]) == "/story"
  end

  test "requires a list of bases for root-relative resolution" do
    assert URL.resolve_root_relative("/story", nil) == "/story"
    assert URL.resolve_root_relative("/story", "https://example.com") == "/story"
  end

  test "accepts only absolute bases with both a scheme and host" do
    bases = [
      "/relative",
      "mailto:reader@example.com",
      "https:///missing-host",
      "https://example.com"
    ]

    assert URL.resolve_root_relative("/story", bases) == "https://example.com/story"
  end

  test "preserves the URL when URI parsing receives a non-binary base" do
    assert URL.resolve_root_relative("/story", [42]) == "/story"
  end
end
