defmodule FeedReader.FeedTest do
  use ExUnit.Case, async: true

  alias FeedReader.Feed

  test "uses empty normalized metadata defaults" do
    assert %Feed{
             title: nil,
             description: nil,
             feed_url: nil,
             html_url: nil,
             type: nil,
             categories: [],
             extensions: %{}
           } = %Feed{}
  end

  test "stores feed metadata and namespace extensions" do
    feed = %Feed{
      title: "Example",
      type: :rss,
      categories: ["news"],
      extensions: %{"urn:example" => %{"priority" => 1}}
    }

    assert feed.title == "Example"
    assert feed.type == :rss
    assert feed.extensions["urn:example"]["priority"] == 1
  end
end
