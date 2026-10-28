defmodule FeedReader.ResultTypesTest do
  use ExUnit.Case, async: true

  alias FeedReader.{Feed, Fetch, Item, ParseResult, RemoteResult, Session}

  test "fetch stores remote HTTP metadata" do
    fetch = %Fetch{
      etag: "\"version-1\"",
      checksum: "d41d8cd98f00b204e9800998ecf8427e",
      final_url: "https://example.com/feed.xml",
      status: 200
    }

    assert fetch.etag == "\"version-1\""
    assert fetch.checksum == "d41d8cd98f00b204e9800998ecf8427e"
    assert fetch.final_url == "https://example.com/feed.xml"
    assert fetch.status == 200
  end

  test "parse results contain local feed data without fetch metadata" do
    item = %Item{uuid: "item-1"}
    result = %ParseResult{feed: %Feed{title: "Example"}, items: [item]}

    assert result.feed.title == "Example"
    assert result.items == [item]
    refute result.item_limit_reached?
    refute Map.has_key?(result, :fetch)
  end

  test "remote results pair collected data with fetch metadata" do
    fetch = %Fetch{checksum: "checksum", final_url: "https://example.com", status: 200}
    result = %RemoteResult{feed: %Feed{}, items: [], fetch: fetch}

    assert result.fetch == fetch
    assert result.items == []
    refute result.item_limit_reached?
  end

  test "sessions distinguish remote and local fetch ownership" do
    events = [{:feed, %Feed{}}]
    remote = %Session{events: events, fetch: %Fetch{status: 200}}
    local = %Session{events: events}

    assert Enum.to_list(remote.events) == events
    assert remote.fetch.status == 200
    assert local.fetch == nil
  end
end
