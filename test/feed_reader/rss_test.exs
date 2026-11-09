defmodule FeedReader.RSSTest do
  use ExUnit.Case, async: true

  alias FeedReader.{Feed, Formats.RSS, Item, Media}
  alias FeedReader.XML.ChildAccumulator

  @media_rss "http://search.yahoo.com/mrss/"

  @xml ~s(<rss version="2.0"><channel><title>Example</title><description>Latest news</description><link>https://example.com/</link><category>News</category><category>Updates</category><item><title>Story</title><guid isPermaLink="false">story-1</guid><link>/story</link><author>Writer</author><description>Summary</description><content:encoded><![CDATA[<p>Full text</p>]]></content:encoded><pubDate>Mon, 24 Feb 2025 17:00:05 GMT</pubDate></item><item><title> </title><link>https://example.com/second</link><pubDate>not a date</pubDate></item><item><title> </title></item></channel></rss>)

  test "format callback normalizes feed metadata and RSS items" do
    sink = fn event -> send(self(), event) end
    assert {:halt, state, _} = parse(@xml, sink)
    assert state.channel["title"] == "Example"
    assert state.channel["category"] == ["News", "Updates"]
    assert_receive {:feed, %FeedReader.Feed{title: "Example", categories: ["News", "Updates"]}}
    assert_receive {:item, %FeedReader.Item{title: "Story", uuid: "story-1"}}
    assert {:halt, _, _} = parse("<rss version='2.0'><channel/></rss>", sink)
  end

  test "snapshots and normalizes the feed once for multiple items" do
    sink = fn event -> send(self(), event) end

    xml =
      "<rss version='2.0'><channel><title>Example</title><link>https://example.com/</link>" <>
        "<item><title>First</title><link>/first</link></item>" <>
        "<description>Late description</description>" <>
        "<item><title>Second</title><link>/second</link></item></channel></rss>"

    assert {:halt, state, _} = parse(xml, sink)
    assert state.channel == %{"title" => "Example", "link" => "https://example.com/"}

    assert state.normalized_feed == %Feed{
             title: "Example",
             html_url: "https://example.com/",
             type: :rss
           }

    assert_receive {:feed, %Feed{title: "Example", description: nil}}
    assert_receive {:item, %Item{title: "First", canonical_url: "https://example.com/first"}}
    assert_receive {:item, %Item{title: "Second", canonical_url: "https://example.com/second"}}
  end

  test "emits only RSS owners at their real paths and expanded names" do
    sink = fn event -> send(self(), event) end

    xml =
      ~s(<rss version="2.0" xmlns:x="urn:foreign"><x:channel><title>Foreign</title><item><title>Foreign item</title></item></x:channel>) <>
        ~s(<wrapper><channel><title>Nested</title><item><title>Nested item</title></item></channel></wrapper>) <>
        ~s(<channel><title>Real</title><link>https://example.com/</link><wrapper><item><title>Nested item</title></item></wrapper>) <>
        ~s(<x:item><title>Foreign item</title></x:item><item><title>Actual item</title><link>/story</link></item></channel></rss>)

    assert {:halt, state, _} = parse(xml, sink)
    assert state.channel["title"] == "Real"
    assert_receive {:feed, %Feed{title: "Real"}}

    assert_receive {:item,
                    %Item{title: "Actual item", canonical_url: "https://example.com/story"}}

    refute_receive {:feed, _}
    refute_receive {:item, _}
  end

  test "applies metadata and item limits only within real RSS owner paths" do
    sink = fn _event -> :ok end

    xml =
      "<rss><wrapper><channel><title>ignored</title><item><title>ignored</title></item>" <>
        "</channel></wrapper></rss>"

    assert {:halt, %{limits: %{scope: :none}}, _} =
             parse(xml, sink, max_feed_metadata_bytes: 0, max_item_bytes: 0)

    assert {:ok, %{error: {:resource_limit, :max_feed_metadata_bytes, 0}}} =
             parse("<rss><channel/></rss>", sink, max_feed_metadata_bytes: 0)

    assert {:ok, %{error: {:resource_limit, :max_item_bytes, 0}}} =
             parse("<rss><channel><item/></channel></rss>", sink, max_item_bytes: 0)
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

  test "collects scoped item candidates in encounter order without duplicating their raw values" do
    state =
      handle_events(
        [
          {:start_element, {"rss", []}},
          {:start_element, {"channel", []}},
          {:start_element, {"item", []}},
          {:start_element, {"enclosure", [{"url", "enclosure.jpg"}]}},
          {:end_element, "enclosure"},
          {:start_element, {"m:content", [{"xmlns:m", @media_rss}, {"url", "content.jpg"}]}},
          {:start_element, {"m:thumbnail", [{"url", "thumbnail.jpg"}]}},
          {:end_element, "m:thumbnail"},
          {:end_element, "m:content"}
        ],
        RSS.new_parser_state(fn _event -> :ok end, [])
      )

    candidates = Media.CandidateSequence.finalize(state.item_candidate_sequence)

    assert Enum.map(candidates, &{&1.name, &1.attributes[{nil, "url"}]}) == [
             {{nil, "enclosure"}, "enclosure.jpg"},
             {{@media_rss, "content"}, "content.jpg"},
             {{@media_rss, "thumbnail"}, "thumbnail.jpg"}
           ]

    assert state.frames |> hd() |> Map.fetch!(:children) |> ChildAccumulator.finalize() == %{}

    assert {:stop, %{error: :invalid_sax_event}} =
             RSS.handler().handle_event(:end_element, "orphan", %{state | frames: []})
  end

  test "normalizes feed candidates and falls back on queue errors" do
    state = %{
      channel: %{},
      feed_candidate_sequence: %Media.CandidateSequence{
        next_position: 2,
        positions: [1, 0],
        values: %{
          0 => %Media.Candidate{name: {nil, "unknown"}},
          1 => %Media.Candidate{
            name: {nil, "image"},
            children: %{{nil, "url"} => "logo.jpg"}
          }
        }
      }
    }

    assert %Feed{media: [%Media{url: "logo.jpg"}]} = RSS.normalize_feed(state, [])
    assert %Feed{media: []} = RSS.normalize_feed(state, max_queue_bytes: 0)
  end

  test "ignores unsupported RSS item media candidates" do
    candidates = %Media.CandidateSequence{
      positions: [0],
      values: %{0 => %Media.Candidate{name: {nil, "image"}}}
    }

    assert {:ok, %Item{media: []}} = RSS.normalize_item_result(%{}, candidates, %Feed{}, [])
  end

  test "normalizes RSS channel images and preserves feed snapshots" do
    xml =
      ~s(<rss version="2.0"><channel><title>Example</title><link>https://example.com/news</link><image><url> /logo.png </url><title> Company logo </title><width>320</width><height>180</height></image><image><url>/small.png</url><width>invalid</width><height>-1</height></image><item><title>Story</title></item><image><url>/late.png</url></image></channel></rss>)

    assert {:ok, %{feed: feed}} = FeedReader.parse_binary(xml)

    assert Enum.map(feed.media, &{&1.url, &1.role, &1.title, &1.width, &1.height}) == [
             {"https://example.com/logo.png", :logo, "Company logo", 320, 180},
             {"https://example.com/small.png", :logo, nil, nil, nil}
           ]

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path)
    assert [{:feed, ^feed}, {:item, _}] = Enum.to_list(events)

    assert {:ok, %{feed: %{media: [%Media{url: "logo.png"}]}}} =
             FeedReader.parse_binary(
               "<rss><channel><image><url>logo.png</url></image></channel></rss>"
             )

    assert {:ok, %{feed: %{media: [%Media{url: "https://example.com/logo.png", title: "Logo"}]}}} =
             FeedReader.parse_binary(
               ~s(<r:rss xmlns:r="http://purl.org/rss/1.0/"><r:channel><r:image><r:url>/logo.png</r:url><r:title>Logo</r:title></r:image></r:channel></r:rss>),
               format: :rss,
               feed_url: "https://example.com/feed.xml"
             )
  end

  test "ignores foreign default-namespaced channel fields when resolving media URLs" do
    xml =
      ~s(<rss xmlns:m="#{@media_rss}"><channel><title>Actual feed</title><title xmlns="urn:foreign">Decoy</title><link>https://good.example/news/</link><link xmlns="urn:foreign">https://decoy.example/</link><item><title>Story</title><m:thumbnail url="/photo.jpg"/></item></channel></rss>)

    assert {:ok, %{feed: feed, items: [%Item{media: [%Media{url: url}]}]}} =
             FeedReader.parse_binary(xml, feed_url: "https://source.example/rss.xml")

    assert feed.title == "Actual feed"
    assert feed.html_url == "https://good.example/news/"
    assert url == "https://good.example/photo.jpg"
  end

  test "normalizes prefixed RSS 1.0 feed and item fields and image enclosures" do
    xml =
      ~s(<r:rss xmlns:r="http://purl.org/rss/1.0/"><r:channel><r:title>Feed</r:title><r:link>https://example.com/news/</r:link><r:item><r:title>Story</r:title><r:link>/story</r:link><r:enclosure url="/cover.jpg" type="image/jpeg"/></r:item></r:channel></r:rss>)

    assert {:ok, %{feed: feed, items: [item]}} = FeedReader.parse_binary(xml, format: :rss)
    assert feed.title == "Feed"
    assert feed.html_url == "https://example.com/news/"
    assert item.title == "Story"
    assert item.canonical_url == "https://example.com/story"
    assert [%Media{url: "https://example.com/cover.jpg", role: :enclosure}] = item.media
  end

  test "normalizes image enclosures and Media RSS content on RSS items" do
    xml =
      ~s(<rss version="2.0"><channel><title>Example</title><link>https://example.com/news</link><item><title>Story</title><guid>story</guid><enclosure url=" /cover.jpg " type="IMAGE/JPEG; charset=binary"/><enclosure url="//cdn.example/detail.png" type="image/png"/><m:content xmlns:m="http://search.yahoo.com/mrss/" url="/deferred.jpg" type="image/jpeg"/><enclosure url="/audio.mp3" type="audio/mpeg"/><enclosure url="/unknown"/><enclosure url="  " type="image/webp"/><x:enclosure xmlns:x="urn:foreign" url="/foreign.png" type="image/png"/></item><item><title>Second</title><enclosure url="/second.png" type="image/png"/></item></channel></rss>)

    assert {:ok, %{feed: feed, items: [first, second]}} = FeedReader.parse_binary(xml)

    assert feed.media == []

    assert first.media == [
             %Media{
               url: "https://example.com/cover.jpg",
               kind: :image,
               role: :enclosure,
               mime_type: "image/jpeg"
             },
             %Media{
               url: "//cdn.example/detail.png",
               kind: :image,
               role: :enclosure,
               mime_type: "image/png"
             },
             %Media{
               url: "https://example.com/deferred.jpg",
               kind: :image,
               role: :content,
               mime_type: "image/jpeg"
             }
           ]

    assert Enum.map(second.media, & &1.url) == ["https://example.com/second.png"]

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path)

    assert [{:feed, ^feed}, {:item, streamed_first}, {:item, streamed_second}] =
             Enum.to_list(events)

    assert Enum.map([streamed_first, streamed_second], & &1.media) ==
             Enum.map([first, second], & &1.media)
  end

  test "normalizes RSS Media RSS resources in encounter order in collection and streaming" do
    xml =
      ~s(<rss xmlns:m="#{@media_rss}" xmlns:x="urn:foreign"><channel><title>Example</title><link>https://example.com/news</link><item><title>Story</title><enclosure url="/cover.jpg" type="image/jpeg"/><m:content url="/content.jpg" medium="image" type="IMAGE/JPEG; q=1" width="640"><m:title>Content</m:title><m:thumbnail url="/nested.jpg"/></m:content><m:group><m:thumbnail url="/group-thumb.jpg"/><m:content url="/group-content.jpg" type="image/png"><m:thumbnail url="/group-nested.jpg"/></m:content></m:group><m:content url="/video.mp4" medium="video"><m:thumbnail url="/video-thumb.jpg"/></m:content><description><m:thumbnail url="/ignored.jpg"/></description><x:content url="/foreign.jpg" type="image/png"/></item></channel></rss>)

    assert {:ok, %{items: [item]}} = FeedReader.parse_binary(xml)

    assert Enum.map(item.media, &{&1.url, &1.role, &1.mime_type, &1.title, &1.width}) == [
             {"https://example.com/cover.jpg", :enclosure, "image/jpeg", nil, nil},
             {"https://example.com/content.jpg", :content, "image/jpeg", "Content", 640},
             {"https://example.com/nested.jpg", :thumbnail, nil, nil, nil},
             {"https://example.com/group-thumb.jpg", :thumbnail, nil, nil, nil},
             {"https://example.com/group-content.jpg", :content, "image/png", nil, nil},
             {"https://example.com/group-nested.jpg", :thumbnail, nil, nil, nil},
             {"https://example.com/video-thumb.jpg", :thumbnail, nil, nil, nil}
           ]

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path)
    assert [{:feed, _feed}, {:item, streamed_item}] = Enum.to_list(events)
    assert streamed_item.media == item.media
  end

  test "rejects oversized RSS Media RSS item events" do
    host = "https://" <> String.duplicate("a", 256) <> ".example"
    feed = %Feed{html_url: host, type: :rss}
    item = elem(RSS.normalize_item(%{"title" => "Story", "guid" => "story"}, feed, []), 1)

    media = %Media{
      url: host <> "/cover.jpg",
      kind: :image,
      role: :content,
      mime_type: "image/jpeg"
    }

    limit = :erlang.external_size({:item, item}) + Media.Size.add(0, media) - 3

    xml =
      ~s|<rss><channel><title>Example</title><link>#{host}</link><item><title>Story</title><guid>story</guid><m:content xmlns:m="#{@media_rss}" url="/cover.jpg" medium="image" type="image/jpeg"/></item></channel></rss>|

    opts = [format: :rss, max_queue_bytes: limit]

    assert {:error, {:resource_limit, :max_queue_bytes, ^limit}} =
             FeedReader.parse_binary(xml, opts)

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path, opts)

    assert [{:feed, _feed}, {:error, {:resource_limit, :max_queue_bytes, ^limit}}] =
             Enum.to_list(events)
  end

  test "rejects RSS item media that exceeds the item-event queue budget" do
    host = "https://" <> String.duplicate("a", 256) <> ".example"
    feed = %Feed{html_url: host, type: :rss}
    item = elem(RSS.normalize_item(%{"title" => "Story", "guid" => "story"}, feed, []), 1)

    media = %Media{
      url: host <> "/cover.jpg",
      kind: :image,
      role: :enclosure,
      mime_type: "image/jpeg"
    }

    limit = :erlang.external_size({:item, item}) + Media.Size.add(0, media) - 3

    xml =
      "<rss><channel><title>Example</title><link>#{host}</link><item><title>Story</title>" <>
        "<guid>story</guid><enclosure url=\"/cover.jpg\" type=\"image/jpeg\"/></item></channel></rss>"

    opts = [format: :rss, max_queue_bytes: limit]

    assert {:error, {:resource_limit, :max_queue_bytes, ^limit}} =
             FeedReader.parse_binary(xml, opts)

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path, opts)

    assert [{:feed, _feed}, {:error, {:resource_limit, :max_queue_bytes, ^limit}}] =
             Enum.to_list(events)
  end

  test "rejects RSS channel media that exceeds the feed-event queue budget" do
    host = "https://" <> String.duplicate("a", 256) <> ".example"
    feed_url = host <> "/feed.xml"
    media = %Media{url: host <> "/logo.png", kind: :image, role: :logo}
    base_feed = %Feed{feed_url: feed_url, type: :rss}
    base_event_size = byte_size(:erlang.term_to_binary({:feed, base_feed}))
    limit = base_event_size + Media.Size.add(0, media) - 3

    xml = "<rss><channel><image><url>/logo.png</url></image><item/></channel></rss>"
    opts = [format: :rss, feed_url: feed_url, max_queue_bytes: limit]

    assert {:error, {:resource_limit, :max_queue_bytes, ^limit}} =
             FeedReader.parse_binary(xml, opts)

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path, opts)
    assert [{:error, {:resource_limit, :max_queue_bytes, ^limit}}] = Enum.to_list(events)
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

    assert %{frames: []} =
             handle_events(
               [start_element: {"orphan", []}, end_element: "orphan"],
               RSS.new_parser_state(sink, [])
             )
  end

  defp parse(xml, sink, opts \\ []),
    do: Saxy.parse_string(xml, RSS.handler(), RSS.new_parser_state(sink, opts))

  defp handle_events(events, state) do
    Enum.reduce(events, state, fn {event, data}, state ->
      {:ok, state} = RSS.handler().handle_event(event, data, state)
      state
    end)
  end

  defp write_temp(contents) do
    path =
      Path.join(System.tmp_dir!(), "feed-reader-rss-#{System.unique_integer([:positive])}.xml")

    File.write!(path, contents)
    path
  end
end
