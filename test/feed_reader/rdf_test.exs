defmodule FeedReader.RDFTest do
  use ExUnit.Case, async: true

  alias FeedReader.{Feed, Formats.RDF, Item, Media}

  @xml """
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel><title xml:lang="en"> Example </title><description>News</description><link>https://example.com/</link><dc:subject>Tech</dc:subject><dc:subject>Tech</dc:subject></channel>
    <item><title>&lt;b&gt;First&lt;/b&gt;</title><link>/first</link><description>Summary</description><dc:creator>Writer</dc:creator><dc:date>2025-03-06T14:00:00+00:00</dc:date></item>
    <item><title>Title only</title></item>
  </rdf:RDF>
  """

  test "implements the format contract and emits feed before normalized RDF items" do
    assert RDF.id() == :rdf
    assert RDF.matches_prefix?("<rdf:RDF>")
    assert RDF.handler() == FeedReader.Formats.RDF.Handler
    sink = fn event -> send(self(), event) end
    assert {:halt, _, _} = parse(@xml, sink)

    assert_receive {:feed,
                    %Feed{title: "Example", description: "News", type: :rdf, categories: ["Tech"]}}

    assert_receive {:item,
                    %Item{
                      title: "First",
                      uuid: "https://example.com/first",
                      canonical_url: "https://example.com/first",
                      content_summary: "Summary",
                      author: "Writer",
                      published_at: ~U[2025-03-06 14:00:00Z]
                    }}

    assert_receive {:item, %Item{title: "Title only", content_full: nil, content_summary: nil}}
  end

  test "preserves scalar and repeated child shapes in RDF channel data" do
    sink = fn event -> send(self(), event) end

    xml =
      "<rdf:RDF><channel><title>Feed</title><dc:subject>Tech</dc:subject><dc:subject>Culture</dc:subject></channel></rdf:RDF>"

    assert {:halt, state, _} = parse(xml, sink)
    assert state.channel["title"] == "Feed"
    assert state.channel["dc:subject"] == ["Tech", "Culture"]
    assert_receive {:feed, %Feed{title: "Feed", categories: ["Tech", "Culture"]}}
  end

  test "uses the emitted feed snapshot when the channel follows the first item" do
    sink = fn event -> send(self(), event) end

    xml =
      "<rdf:RDF><item><title>First</title><link>/first</link></item>" <>
        "<channel><title>Late channel</title><link>https://example.com/</link></channel>" <>
        "<item><title>Second</title><link>/second</link></item></rdf:RDF>"

    assert {:halt, state, _} = parse(xml, sink)
    assert state.channel == %{}
    assert state.normalized_feed == %Feed{type: :rdf}

    assert_receive {:feed, %Feed{title: nil, html_url: nil, type: :rdf}}
    assert_receive {:item, %Item{title: "First", canonical_url: "/first"}}
    assert_receive {:item, %Item{title: "Second", canonical_url: "/second"}}
    refute_receive {:feed, _}
  end

  test "emits only direct RDF channel and item owners" do
    sink = fn event -> send(self(), event) end

    xml = """
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:x="urn:extension">
      <wrapper>
        <channel><title>Nested channel</title></channel>
        <item><title>Nested item</title></item>
      </wrapper>
      <x:channel><title>Prefixed extension channel</title></x:channel>
      <channel xmlns="urn:extension"><title>Default extension channel</title></channel>
      <x:item><title>Prefixed extension item</title></x:item>
      <item xmlns="urn:extension"><title>Default extension item</title></item>
      <channel>
        <title>Real channel</title>
        <item><title>Nested channel item</title></item>
      </channel>
      <item><title>Real item</title><link>/story</link></item>
    </rdf:RDF>
    """

    assert {:halt, _state, _} = parse(xml, sink)
    assert_receive {:feed, %Feed{title: "Real channel"}}
    assert_receive {:item, %Item{title: "Real item", canonical_url: "/story"}}
    refute_receive {:feed, _}
    refute_receive {:item, _}
  end

  test "collects scoped RDF media candidates in encounter order" do
    sink = fn event -> send(self(), event) end

    xml = """
    <r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:s="http://purl.org/rss/1.0/"
           xmlns:q="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:x="urn:extension" xmlns:m="http://search.yahoo.com/mrss/">
      <s:channel>
        <s:image q:resource="/logo"><s:title>Logo</s:title></s:image>
        <s:image resource="/unqualified"/><s:image x:resource="/foreign"/>
      </s:channel>
      <s:item>
        <m:content url="/content"><m:thumbnail url="/nested"/></m:content>
        <m:group><m:thumbnail url="/group"/></m:group>
        <wrapper><m:content url="/decoy"/></wrapper>
      </s:item>
      <s:channel><s:image q:resource="/late"/></s:channel>
    </r:RDF>
    """

    assert {:halt, state, _} = parse(xml, sink)

    assert [
             %{
               name: {"http://purl.org/rss/1.0/", "image"},
               attributes: attributes,
               children: children
             }
           ] =
             Media.CandidateSequence.finalize(state.feed_candidate_sequence)

    assert attributes[{"http://www.w3.org/1999/02/22-rdf-syntax-ns#", "resource"}] == "/logo"
    assert children[{"http://purl.org/rss/1.0/", "title"}] == "Logo"

    assert Enum.map(
             Media.CandidateSequence.finalize(state.item_candidate_sequence),
             & &1.name
           ) ==
             [
               {"http://search.yahoo.com/mrss/", "content"},
               {"http://search.yahoo.com/mrss/", "thumbnail"},
               {"http://search.yahoo.com/mrss/", "thumbnail"}
             ]
  end

  test "normalizes direct RDF channel image references in collection and streaming" do
    xml =
      ~s(<r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:s="http://purl.org/rss/1.0/" xmlns:q="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><s:channel><s:title>Example</s:title><s:link>https://example.com/news/</s:link><s:image q:resource=" /logo.png "><s:title> Brand </s:title><s:width>320</s:width><s:height>180</s:height></s:image></s:channel><s:item><s:title>Story</s:title></s:item><s:channel><s:image q:resource="/late.png"/></s:channel></r:RDF>)

    opts = [format: :rdf]
    assert {:ok, %{feed: feed, items: [_item]}} = FeedReader.parse_binary(xml, opts)

    assert [
             %Media{
               url: "https://example.com/logo.png",
               kind: :image,
               role: :logo,
               mime_type: nil,
               title: "Brand",
               width: 320,
               height: 180
             }
           ] = feed.media

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path, opts)
    assert [{:feed, ^feed}, {:item, _item}] = Enum.to_list(events)

    empty_xml =
      ~s(<r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:s="http://purl.org/rss/1.0/" xmlns:q="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><s:channel><s:image q:resource="/logo.png"/></s:channel></r:RDF>)

    assert {:ok, %{feed: %{media: [%Media{url: "https://example.org/logo.png"}]}, items: []}} =
             FeedReader.parse_binary(empty_xml,
               format: :rdf,
               feed_url: "https://example.org/feed.rdf"
             )
  end

  test "ignores foreign default-namespaced channel fields when resolving media URLs" do
    xml =
      "<rdf:RDF><channel><title>Actual feed</title><title xmlns='urn:foreign'>Decoy</title>" <>
        "<link>https://good.example/news/</link><link xmlns='urn:foreign'>https://decoy.example/</link></channel>" <>
        "<item><title>Story</title><m:thumbnail xmlns:m='http://search.yahoo.com/mrss/' " <>
        "url='/photo.jpg'/></item></rdf:RDF>"

    assert {:ok, %{feed: feed, items: [%Item{media: [%Media{url: url}]}]}} =
             FeedReader.parse_binary(xml,
               format: :rdf,
               feed_url: "https://source.example/feed.rdf"
             )

    assert feed.title == "Actual feed"
    assert feed.html_url == "https://good.example/news/"
    assert url == "https://good.example/photo.jpg"
  end

  test "normalizes RDF Media RSS item resources in encounter order" do
    xml = """
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
             xmlns:m="http://search.yahoo.com/mrss/" xmlns:x="urn:foreign">
      <channel><title>Example</title><link>https://example.com/news/</link></channel>
      <item><title>Story</title><guid>story</guid>
        <m:content url="/content.jpg" medium="image" type="IMAGE/JPEG; q=1" width="640">
          <m:title>Content</m:title><m:thumbnail url="/nested.jpg"/>
        </m:content>
        <m:group><m:thumbnail url="/group-thumb.jpg"/>
          <m:content url="/group-content.jpg" type="image/png">
            <m:thumbnail url="/group-nested.jpg"/>
          </m:content>
        </m:group>
        <m:content url="/video.mp4" medium="video"><m:thumbnail url="/video-thumb.jpg"/></m:content>
        <description><m:thumbnail url="/ignored.jpg"/></description>
        <x:content url="/foreign.jpg" type="image/png"/>
      </item>
    </rdf:RDF>
    """

    assert {:ok, %{feed: feed, items: [item]}} = FeedReader.parse_binary(xml, format: :rdf)

    assert Enum.map(item.media, &{&1.url, &1.role, &1.mime_type, &1.title, &1.width}) == [
             {"https://example.com/content.jpg", :content, "image/jpeg", "Content", 640},
             {"https://example.com/nested.jpg", :thumbnail, nil, nil, nil},
             {"https://example.com/group-thumb.jpg", :thumbnail, nil, nil, nil},
             {"https://example.com/group-content.jpg", :content, "image/png", nil, nil},
             {"https://example.com/group-nested.jpg", :thumbnail, nil, nil, nil},
             {"https://example.com/video-thumb.jpg", :thumbnail, nil, nil, nil}
           ]

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path, format: :rdf)
    assert [{:feed, ^feed}, {:item, streamed_item}] = Enum.to_list(events)
    assert streamed_item.media == item.media
  end

  test "rejects oversized RDF Media RSS item events" do
    host = "https://" <> String.duplicate("a", 256) <> ".example/"
    feed = %Feed{html_url: host, type: :rdf}
    raw = %{"title" => "Story", "guid" => "story"}
    item = elem(RDF.normalize_item(raw, feed, []), 1)

    media = %Media{
      url: host <> "cover.jpg",
      kind: :image,
      role: :content,
      mime_type: "image/jpeg"
    }

    limit = :erlang.external_size({:item, item}) + Media.Size.add(0, media) - 3

    xml =
      "<rdf:RDF><channel><title>Example</title><link>#{host}</link></channel><item>" <>
        "<title>Story</title><guid>story</guid><m:content xmlns:m='http://search.yahoo.com/mrss/' " <>
        "url='/cover.jpg' medium='image' type='image/jpeg'/></item></rdf:RDF>"

    opts = [format: :rdf, max_queue_bytes: limit]

    assert {:error, {:resource_limit, :max_queue_bytes, ^limit}} =
             FeedReader.parse_binary(xml, opts)

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path, opts)

    assert [{:feed, _feed}, {:error, {:resource_limit, :max_queue_bytes, ^limit}}] =
             Enum.to_list(events)
  end

  test "ignores unsupported RDF item media candidates" do
    candidates = candidate_sequence([%Media.Candidate{name: {nil, "other"}}])

    assert {:ok, %Item{media: []}} =
             RDF.normalize_item_result(%{"title" => "Story"}, candidates, %Feed{}, [])
  end

  test "rejects RDF feed media that exceeds the feed-event queue budget" do
    feed_url = "https://" <> String.duplicate("a", 300) <> ".example/feed.rdf"

    media_url = String.replace_suffix(feed_url, "/feed.rdf", "/logo.png")
    media = %Media{url: media_url, kind: :image, role: :logo}

    limit =
      byte_size(:erlang.term_to_binary({:feed, %Feed{feed_url: feed_url, type: :rdf}})) +
        Media.Size.add(0, media) - 3

    xml =
      ~s(<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><channel><image rdf:resource="/logo.png"/></channel></rdf:RDF>)

    opts = [format: :rdf, feed_url: feed_url, max_queue_bytes: limit]

    assert {:error, {:resource_limit, :max_queue_bytes, ^limit}} =
             FeedReader.parse_binary(xml, opts)

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path, opts)
    assert [{:error, {:resource_limit, :max_queue_bytes, ^limit}}] = Enum.to_list(events)
  end

  test "applies XML byte limits only inside direct RDF owners" do
    sink = fn event -> send(self(), event) end

    decoys = """
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:x="urn:extension">
      <wrapper><channel><title>Nested</title></channel><item><title>Nested</title></item></wrapper>
      <x:channel><title>Extension</title></x:channel>
      <x:item><title>Extension</title></x:item>
      <channel xmlns="urn:extension"><title>Default extension</title></channel>
      <item xmlns="urn:extension"><title>Default extension</title></item>
    </rdf:RDF>
    """

    assert {:halt, state, _} =
             parse(decoys, sink, max_feed_metadata_bytes: 0, max_item_bytes: 0)

    assert state.channel == nil
    assert state.normalized_feed == nil
    refute_receive {:feed, _}
    refute_receive {:item, _}

    assert {:ok, %{error: {:resource_limit, :max_feed_metadata_bytes, 0}}} =
             parse("<rdf:RDF><channel/></rdf:RDF>", sink, max_feed_metadata_bytes: 0)

    assert {:ok, %{error: {:resource_limit, :max_item_bytes, 0}}} =
             parse("<rdf:RDF><item/></rdf:RDF>", sink, max_item_bytes: 0)
  end

  test "continues to accept namespace-less legacy RDF roots and owners" do
    sink = fn event -> send(self(), event) end

    assert {:halt, _, _} =
             parse(
               "<RDF><channel><title>Legacy</title></channel><item><title>Story</title></item></RDF>",
               sink
             )

    assert_receive {:feed, %Feed{title: "Legacy"}}
    assert_receive {:item, %Item{title: "Story"}}
  end

  test "parses aliased and default RDF roots with prefixed RSS 1.0 names explicitly" do
    aliased_xml = """
    <r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
            xmlns:s="http://purl.org/rss/1.0/" xmlns:x="urn:extension">
      <x:channel><s:title>Foreign channel</s:title></x:channel>
      <s:channel>
        <s:title>Aliased feed</s:title>
        <s:link>https://example.com/news/</s:link>
        <x:title>Foreign feed title</x:title>
        <x:link>https://decoy.example/</x:link>
      </s:channel>
      <s:item>
        <s:title>Aliased story</s:title>
        <s:link>/story</s:link>
        <x:title>Foreign item title</x:title>
        <x:link>/decoy</x:link>
      </s:item>
      <x:item><s:title>Foreign item</s:title></x:item>
      <wrapper><s:item><s:title>Nested item</s:title></s:item></wrapper>
    </r:RDF>
    """

    assert {:ok, aliased} = FeedReader.parse_binary(aliased_xml, format: :rdf)
    assert aliased.feed.title == "Aliased feed"
    assert aliased.feed.html_url == "https://example.com/news/"

    assert [%Item{title: "Aliased story", canonical_url: "https://example.com/story"}] =
             aliased.items

    default_xml = """
    <RDF xmlns="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:s="http://purl.org/rss/1.0/">
      <s:channel>
        <s:title>Default-root feed</s:title>
        <s:link>https://example.org/</s:link>
      </s:channel>
      <s:item><s:title>Default-root story</s:title><s:link>/story</s:link></s:item>
    </RDF>
    """

    assert {:ok, default_root} = FeedReader.parse_binary(default_xml, format: :rdf)
    assert default_root.feed.title == "Default-root feed"

    assert [%Item{title: "Default-root story", canonical_url: "https://example.org/story"}] =
             default_root.items
  end

  test "preserves relative links when no absolute feed base is available" do
    raw = %{"title" => "Story", "link" => "/story"}

    assert {:ok, %Item{canonical_url: "/story"}} =
             RDF.normalize_item(raw, %Feed{html_url: "/"}, [])

    assert {:ok, %Item{canonical_url: "https://example.com/story"}} =
             RDF.normalize_item(
               raw,
               %Feed{html_url: "/", feed_url: "https://example.com/feed.xml"},
               []
             )
  end

  test "enforces shared SAX limits and reports malformed XML" do
    sink = fn _event -> :ok end

    assert {:ok, %{error: {:resource_limit, :max_item_bytes, 1}}} =
             parse(@xml, sink, max_item_bytes: 1)

    assert {:ok, %{error: {:resource_limit, :max_item_bytes, 10}}} =
             parse("<rdf:RDF><channel/><item><title>First</title></item></rdf:RDF>", sink,
               max_item_bytes: 10
             )

    assert {:ok, %{error: {:resource_limit, :max_item_bytes, 4}}} =
             parse("<rdf:RDF><channel/><item/></rdf:RDF>", sink, max_item_bytes: 4)

    assert {:ok, %{error: {:resource_limit, :max_feed_metadata_bytes, 1}}} =
             parse(@xml, sink, max_feed_metadata_bytes: 1)

    assert {:error, _reason} = parse("<rdf:RDF>", sink)
  end

  test "emits fallback metadata before the first item when a channel is absent" do
    sink = fn event -> send(self(), event) end

    assert {:halt, _, _} = parse("<rdf:RDF><item><title>Orphan</title></item></rdf:RDF>", sink)
    assert_receive {:feed, %Feed{title: nil, type: :rdf}}
    assert_receive {:item, %Item{title: "Orphan"}}
  end

  test "normalizes feed title fallbacks and non-map channel data" do
    assert %Feed{
             title: "Description fallback",
             description: "Description fallback",
             feed_url: "https://example.com/feed.rdf",
             html_url: "https://example.com/",
             categories: []
           } =
             RDF.normalize_feed(
               %{
                 channel: %{
                   "description" => "Description fallback",
                   "link" => "https://example.com/"
                 }
               },
               feed_url: "https://example.com/feed.rdf"
             )

    assert %Feed{title: "https://example.com/", html_url: "https://example.com/"} =
             RDF.normalize_feed(%{channel: %{"link" => "https://example.com/"}}, [])

    assert %Feed{title: nil, categories: []} = RDF.normalize_feed(%{channel: nil}, [])
  end

  test "ignores candidates without an RDF image resource" do
    candidates = [
      %Media.Candidate{name: {"urn:foreign", "image"}},
      %Media.Candidate{
        name: {"http://purl.org/rss/1.0/", "image"},
        attributes: %{{"http://www.w3.org/1999/02/22-rdf-syntax-ns#", "resource"} => " "}
      }
    ]

    state = %{channel: %{}, feed_candidate_sequence: candidate_sequence(candidates)}

    assert {:ok, %Feed{media: []}} = RDF.normalize_feed_result(state, [])
  end

  test "falls back to feed metadata when normalized media exceeds the queue budget" do
    candidate = %Media.Candidate{
      name: {"http://purl.org/rss/1.0/", "image"},
      attributes: %{{"http://www.w3.org/1999/02/22-rdf-syntax-ns#", "resource"} => "/logo.png"}
    }

    state = %{
      channel: %{"title" => "Example"},
      feed_candidate_sequence: candidate_sequence([candidate])
    }

    assert %Feed{title: "Example", media: [], type: :rdf} =
             RDF.normalize_feed(state, max_queue_bytes: 0)
  end

  test "normalizes blank titles, invalid dates, and empty language input" do
    before = DateTime.utc_now(:second)

    assert {:ok,
            %Item{title: nil, content_summary: nil, published_at: published_at, language: :en}} =
             RDF.normalize_item(%{"title" => "  ", "dc:date" => "not a date"}, %Feed{}, [])

    assert DateTime.compare(published_at, before) in [:eq, :gt]
  end

  test "stops on SAX accounting errors and rejects orphan events" do
    handler = RDF.handler()
    sink = fn _event -> :ok end
    limited = RDF.new_parser_state(sink, max_xml_events: 0)

    assert {:stop, %{error: {:resource_limit, :max_xml_events, 0}}} =
             handler.handle_event(:start_element, {"root", []}, limited)

    assert {:stop, %{error: {:resource_limit, :max_xml_events, 0}}} =
             handler.handle_event(:start_document, [], limited)

    state = RDF.new_parser_state(sink, [])

    assert {:stop, %{error: :invalid_sax_event}} =
             handler.handle_event(:characters, "text", state)

    assert {:stop, %{error: :invalid_sax_event}} =
             handler.handle_event(:end_element, "item", state)

    state = %{state | limits: %{state.limits | depth: 1}}

    assert {:stop, %{error: :invalid_sax_event}} =
             handler.handle_event(:end_element, "item", state)
  end

  defp parse(xml, sink, opts \\ []),
    do: Saxy.parse_string(xml, RDF.handler(), RDF.new_parser_state(sink, opts))

  defp candidate_sequence(candidates) do
    Enum.reduce(candidates, Media.CandidateSequence.new(), fn candidate, sequence ->
      {sequence, position} = Media.CandidateSequence.start(sequence)
      Media.CandidateSequence.complete(sequence, position, candidate)
    end)
  end

  defp write_temp(contents) do
    path =
      Path.join(System.tmp_dir!(), "feed-reader-rdf-#{System.unique_integer([:positive])}.xml")

    File.write!(path, contents)
    path
  end
end
