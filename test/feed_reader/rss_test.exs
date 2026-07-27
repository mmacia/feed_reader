defmodule FeedReader.RSSTest do
  use ExUnit.Case, async: true

  alias FeedReader.{Feed, Formats.RSS, Item}

  @xml ~s(<rss version="2.0"><channel><title>Example</title><description>Latest news</description><link>https://example.com/</link><category>News</category><category>News</category><item><title>Story</title><guid isPermaLink="false">story-1</guid><link>/story</link><author>Writer</author><description>Summary</description><content:encoded><![CDATA[<p>Full text</p>]]></content:encoded><pubDate>Mon, 24 Feb 2025 17:00:05 GMT</pubDate></item><item><title> </title><link>https://example.com/second</link><pubDate>not a date</pubDate></item><item><title> </title></item></channel></rss>)

  test "format callback normalizes feed metadata and RSS items" do
    sink = fn event -> send(self(), event) end
    assert {:halt, _, _} = parse(@xml, sink)
    assert_receive {:feed, %FeedReader.Feed{title: "Example", categories: ["News"]}}
    assert_receive {:item, %FeedReader.Item{title: "Story", uuid: "story-1"}}
    assert {:halt, _, _} = parse("<rss version='2.0'><channel/></rss>", sink)
  end

  test "preserves relative links when no absolute feed base is available" do
    assert {:ok, %Item{canonical_url: "/story"}} =
             RSS.normalize_item(
               %{"title" => "Story", "link" => "/story"},
               %Feed{html_url: "/"},
               []
             )

    assert {:ok, %Item{canonical_url: "https://example.com/story"}} =
             RSS.normalize_item(
               %{"title" => "Story", "link" => "/story"},
               %Feed{html_url: "/", feed_url: "https://example.com/feed.xml"},
               []
             )
  end

  test "stops malformed and over-budget input and rejects orphan SAX events" do
    sink = fn _event -> :ok end
    assert {:error, _} = parse("<rss version='2.0'>", sink)

    assert {:ok, %{error: {:resource_limit, :max_item_bytes, 1}}} =
             parse(@xml, sink, max_item_bytes: 1)

    for {opts, events, error} <- [
          {[max_xml_events: 0], [start_document: [], characters: "x", end_element: "item"],
           {:resource_limit, :max_xml_events, 0}},
          {[], [characters: "x", end_element: "item"], :invalid_sax_event}
        ] do
      state = RSS.new_parser_state(sink, opts)

      for {event, data} <- events do
        assert {:stop, %{error: ^error}} = RSS.handler().handle_event(event, data, state)
      end
    end
  end

  defp parse(xml, sink, opts \\ []),
    do: Saxy.parse_string(xml, RSS.handler(), RSS.new_parser_state(sink, opts))
end
