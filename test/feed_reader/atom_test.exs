defmodule FeedReader.AtomTest do
  use ExUnit.Case, async: true
  alias FeedReader.{Feed, Formats.Atom, Item, Media}

  @xml ~s(<feed xmlns="http://www.w3.org/2005/Atom"><title>News</title><subtitle>Updates</subtitle><link rel="alternate" href="https://example.com/"/><category term="Tech"/><category term="Culture"/><entry><title>Story</title><id>tag:example.com,2025:1</id><link href="/story"/><author><name>Writer</name></author><published>2025-02-24T17:00:05Z</published><content type="html">&lt;p&gt;Full text&lt;/p&gt;</content><summary>Brief</summary></entry></feed>)
  @xhtml ~s(<feed><title>Feed</title><id>https://example.com/fallback</id><entry><content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Hello <b>world</b></p></div></content></entry><entry><title>12345</title><link href="https://example.com/item"/><published>not a date</published></entry></feed>)

  test "identifies Atom feed prefixes and format" do
    assert Atom.matches_prefix?("<FEED xmlns='http://www.w3.org/2005/Atom'>")
    refute Atom.matches_prefix?("<entry/>")
    assert Atom.id() == :atom
  end

  test "normalizes feed metadata and entry fields" do
    assert {:halt, state, _} = parse(@xml)
    assert %{"_text" => "News"} = state.feed["title"]
    assert Enum.map(state.feed["category"], & &1["term"]) == ["Tech", "Culture"]
    assert_receive {:feed, %Feed{title: "News", type: :atom, categories: ["Tech", "Culture"]}}

    assert_receive {:item, %Item{content_full: "<p>Full text</p>"}}
    assert %Feed{html_url: nil} = Atom.normalize_feed(%{feed: %{}}, [])

    assert {:halt, _, _} = parse(@xhtml)

    assert_receive {:feed, %Feed{html_url: "https://example.com/fallback"}}
    assert_receive {:item, %Item{content_full: xhtml, content_summary: nil}}
    assert xhtml == "<div xmlns=\"http://www.w3.org/1999/xhtml\"><p>Hello <b>world</b></p></div>"
    assert_receive {:item, %Item{title: "12345", content_summary: "12345"}}
  end

  test "snapshots and normalizes the feed once for multiple entries" do
    sink = fn event -> send(self(), event) end

    xml =
      "<feed><title>News</title><link rel='alternate' href='https://example.com/'/>" <>
        "<icon> /icon.png </icon><logo>https://cdn.example/logo.svg</logo>" <>
        "<entry><title>First</title><link href='/first'/></entry>" <>
        "<subtitle>Late updates</subtitle><icon>/late-icon.png</icon><logo>/late-logo.png</logo>" <>
        "<entry><title>Second</title><link href='/second'/></entry></feed>"

    assert {:halt, state, _} =
             Saxy.parse_string(xml, Atom.handler(), Atom.new_parser_state(sink, []))

    assert state.feed["subtitle"] == nil

    assert_receive {:feed, %Feed{title: "News", description: nil}}
    assert_receive {:item, %Item{title: "First", canonical_url: "https://example.com/first"}}
    assert_receive {:item, %Item{title: "Second", canonical_url: "https://example.com/second"}}

    assert {:ok, %{feed: collected, items: [_, _]}} = FeedReader.parse_binary(xml)
    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path)

    assert [{:feed, ^collected}, {:item, _}, {:item, _}] = Enum.to_list(events)
    assert collected == state.normalized_feed

    assert Enum.map(collected.media, &{&1.url, &1.role}) == [
             {"https://example.com/icon.png", :icon},
             {"https://cdn.example/logo.svg", :logo}
           ]

    xml =
      "<a:feed xmlns:a='http://www.w3.org/2005/Atom'><a:title>Empty</a:title>" <>
        "<a:icon>/icon.png</a:icon><a:logo>/logo.png</a:logo></a:feed>"

    assert {:ok, %{feed: %Feed{media: [icon, logo]}, items: []}} = FeedReader.parse_binary(xml)
    assert {icon.url, icon.role, logo.url, logo.role} == {"/icon.png", :icon, "/logo.png", :logo}
  end

  test "normalizes Atom image enclosures and external image content in encounter order" do
    xml = """
    <a:feed xmlns:a="http://www.w3.org/2005/Atom" xmlns:x="urn:foreign">
      <a:title>News</a:title><a:link rel="alternate" href="https://example.com/news/"/>
      <a:entry><a:title>Story</a:title><a:id>story</a:id>
        <a:link rel="enclosure" href=" /cover.jpg " type="IMAGE/JPEG; charset=binary"/>
        <a:link rel="alternate" href="/ordinary.png" type="image/png"/>
        <a:link rel="enclosure" href="/untyped.jpg"/>
        <a:content src="/body.webp" type="image/WEBP; profile=one"/>
        <a:link rel="enclosure" href="//cdn.example/attached.png" type="image/png"/>
        <a:content src="/page.html" type="text/html"/>
        <a:content src="  " type="image/png"/>
        <a:content type="image/png">inline content</a:content>
        <x:link rel="enclosure" href="/foreign.jpg" type="image/jpeg"/>
      </a:entry>
    </a:feed>
    """

    assert {:ok, %{feed: feed, items: [item]}} = FeedReader.parse_binary(xml)

    expected = [
      {"https://example.com/cover.jpg", :enclosure, "image/jpeg"},
      {"https://example.com/body.webp", :content, "image/webp"},
      {"//cdn.example/attached.png", :enclosure, "image/png"}
    ]

    assert Enum.map(item.media, &{&1.url, &1.role, &1.mime_type}) == expected

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path)
    assert [{:feed, ^feed}, {:item, streamed_item}] = Enum.to_list(events)
    assert Enum.map(streamed_item.media, &{&1.url, &1.role, &1.mime_type}) == expected
  end

  test "normalizes Atom Media RSS resources in encounter order in collection and streaming" do
    xml = """
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:m="http://search.yahoo.com/mrss/" xmlns:x="urn:foreign">
      <title>News</title><link rel="alternate" href="https://example.com/news/"/>
      <entry><title>Story</title>
        <link rel="enclosure" href="/cover.jpg" type="image/jpeg"/>
        <content src="/external.png" type="image/png"/>
        <m:content url="/content.jpg" medium="image" type="IMAGE/JPEG; q=1" width="640">
          <m:title>Content</m:title><m:thumbnail url="/nested.jpg"/>
        </m:content>
        <m:group><m:thumbnail url="/group-thumb.jpg"/>
          <m:content url="/group-content.jpg" type="image/png">
            <m:thumbnail url="/group-nested.jpg"/>
          </m:content>
        </m:group>
        <m:content url="/video.mp4" medium="video"><m:thumbnail url="/video-thumb.jpg"/></m:content>
        <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><m:thumbnail url="/xhtml.jpg"/></div></content>
        <summary><m:thumbnail url="/summary.jpg"/></summary>
        <x:content url="/foreign.jpg" type="image/png"/>
      </entry>
    </feed>
    """

    assert {:ok, %{feed: feed, items: [item]}} = FeedReader.parse_binary(xml)

    assert Enum.map(item.media, &{&1.url, &1.role, &1.mime_type, &1.title, &1.width}) == [
             {"https://example.com/cover.jpg", :enclosure, "image/jpeg", nil, nil},
             {"https://example.com/external.png", :content, "image/png", nil, nil},
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
    assert [{:feed, ^feed}, {:item, streamed_item}] = Enum.to_list(events)
    assert streamed_item.media == item.media
  end

  test "preserves order and uniqueness for thousands of interleaved media resources" do
    media_xml =
      Enum.map_join(1..1_000, fn index ->
        "<link rel='enclosure' href='/enclosure/#{index}.jpg' type='image/jpeg'/>" <>
          "<m:content url='/content/#{index}.jpg' medium='image' type='image/jpeg'/>" <>
          "<m:thumbnail url='/thumbnail/#{index}.jpg'/>"
      end)

    xml =
      "<feed xmlns:m='http://search.yahoo.com/mrss/'><title>Scale</title>" <>
        "<link rel='alternate' href='https://example.com/'/><entry><title>Story</title>" <>
        media_xml <> "</entry></feed>"

    assert {:ok, %{items: [%Item{media: media}]}} = FeedReader.parse_binary(xml, format: :atom)
    assert length(media) == 3_000
    assert Enum.uniq_by(media, & &1.url) == media

    expected_urls =
      for index <- 1..1_000,
          type <- ["enclosure", "content", "thumbnail"],
          do: "https://example.com/#{type}/#{index}.jpg"

    assert Enum.map(media, & &1.url) == expected_urls

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path, format: :atom)
    assert [{:feed, _feed}, {:item, %Item{media: ^media}}] = Enum.to_list(events)
  end

  test "rejects oversized Atom Media RSS entry events" do
    host = "https://" <> String.duplicate("a", 256) <> ".example/"
    feed = %Feed{html_url: host, type: :atom}
    item = elem(Atom.normalize_item(%{"id" => "story", "title" => "Story"}, feed, []), 1)

    media = %Media{
      url: host <> "photo.jpg",
      kind: :image,
      role: :content,
      mime_type: "image/jpeg"
    }

    limit = :erlang.external_size({:item, item}) + Media.Size.add(0, media) - 3

    xml =
      "<feed><title>News</title><link rel='alternate' href='#{host}'/><entry><title>Story</title>" <>
        "<id>story</id><m:content xmlns:m='http://search.yahoo.com/mrss/' url='/photo.jpg' " <>
        "medium='image' type='image/jpeg'/></entry></feed>"

    opts = [format: :atom, max_queue_bytes: limit]

    assert {:error, {:resource_limit, :max_queue_bytes, ^limit}} =
             FeedReader.parse_binary(xml, opts)

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path, opts)

    assert [{:feed, _feed}, {:error, {:resource_limit, :max_queue_bytes, ^limit}}] =
             Enum.to_list(events)
  end

  test "rejects Atom feed media that exceeds the feed-event queue budget" do
    host = "https://" <> String.duplicate("a", 256) <> ".example/"
    feed = %Feed{title: "News", html_url: host, type: :atom}
    media = %Media{url: host <> "logo.png", kind: :image, role: :icon}
    limit = :erlang.external_size({:feed, feed}) + Media.Size.add(0, media) - 3

    xml =
      "<feed><title>News</title><link rel='alternate' href='#{host}'/><icon>/logo.png</icon></feed>"

    opts = [format: :atom, max_queue_bytes: limit]

    assert {:error, {:resource_limit, :max_queue_bytes, ^limit}} =
             FeedReader.parse_binary(xml, opts)

    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{events: events}} = FeedReader.stream_file(path, opts)
    assert [{:error, {:resource_limit, :max_queue_bytes, ^limit}}] = Enum.to_list(events)
  end

  test "collects scoped media candidates in encounter order without entering XHTML" do
    xml =
      ~s(<feed xmlns:m="http://search.yahoo.com/mrss/"><icon>/icon.png</icon><entry><link href="/story"/><m:content url="/content"><m:thumbnail url="/nested"/></m:content><content type="xhtml"><div><m:content url="/xhtml"/></div></content></entry><logo>/late.png</logo></feed>)

    assert {:halt, state, _} = parse(xml)

    assert [_] = Media.CandidateSequence.finalize(state.feed_candidate_sequence)
    candidates = Media.CandidateSequence.finalize(state.item_candidate_sequence)
    assert Enum.map(candidates, &elem(&1.name, 1)) == ["link", "content", "thumbnail", "content"]
    {handler, empty} = {Atom.handler(), Atom.new_parser_state(fn _ -> :ok end, [])}
    {:ok, empty} = handler.handle_event(:start_element, {"feed", []}, empty)

    {:ok, %{frames: [candidate, _]} = empty} =
      handler.handle_event(:start_element, {"icon", []}, empty)

    # Force the defensive no-parent branch after starting a valid feed candidate.
    assert {:ok, _} = handler.handle_event(:end_element, "icon", %{empty | frames: [candidate]})
  end

  test "emits only Atom owners at their real paths and expanded names" do
    xml = """
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:x="urn:extension">
      <title>Real feed</title>
      <link rel="alternate" href="https://example.com/"/>
      <x:feed><title>Extension feed</title><entry><title>Extension nested</title></entry></x:feed>
      <wrapper><entry><title>Nested decoy</title></entry></wrapper>
      <entry>
        <title>Actual item</title>
        <link href="/story"/>
        <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><entry><title>XHTML decoy</title></entry><p>Body</p></div></content>
      </entry>
      <x:entry><title>Extension entry</title></x:entry>
    </feed>
    """

    assert {:halt, _state, _} = parse(xml)
    assert_receive {:feed, %Feed{title: "Real feed"}}

    assert_receive {:item,
                    %Item{title: "Actual item", canonical_url: "https://example.com/story"} = item}

    assert item.content_full =~ "XHTML decoy"

    refute_receive {:feed, _}
    refute_receive {:item, _}
  end

  test "normalizes prefixed Atom metadata with explicit format and ignores foreign names" do
    xml = """
    <a:feed xmlns:a="http://www.w3.org/2005/Atom" xmlns:x="urn:extension">
      <a:title>Prefixed feed</a:title>
      <x:title>Foreign feed title</x:title>
      <title xmlns="urn:extension">Default-namespace decoy</title>
      <a:link rel="alternate" href="https://example.com/"/>
      <x:link rel="alternate" href="https://decoy.example/"/>
       <a:entry>
        <a:title>Prefixed story</a:title>
        <x:title>Foreign story title</x:title>
        <a:link href="/story"/>
        <x:link href="/decoy"/>
        <a:content type="html">Story body</a:content>
        <x:content>Foreign body</x:content>
      </a:entry>
      <x:entry><a:title>Foreign entry</a:title></x:entry>
    </a:feed>
    """

    assert {:ok, result} = FeedReader.parse_binary(xml, format: :atom)
    assert result.feed.title == "Prefixed feed"
    assert result.feed.html_url == "https://example.com/"

    assert [%Item{} = item] = result.items
    assert item.title == "Prefixed story"
    assert item.canonical_url == "https://example.com/story"
    assert item.content_full == "Story body"
  end

  test "applies metadata and item limits only within real Atom owner paths" do
    sink = fn event -> send(self(), event) end

    decoys = """
    <wrapper xmlns="http://www.w3.org/2005/Atom" xmlns:x="urn:extension">
      <feed><title>Nested feed</title><entry><title>Nested item</title></entry></feed>
      <x:feed><title>Extension feed</title><entry><title>Extension item</title></entry></x:feed>
    </wrapper>
    """

    assert {:ok, _state} =
             Saxy.parse_string(
               decoys,
               Atom.handler(),
               Atom.new_parser_state(sink, max_feed_metadata_bytes: 0, max_item_bytes: 0)
             )

    refute_receive {:feed, _}
    refute_receive {:item, _}

    assert {:ok, %{error: {:resource_limit, :max_feed_metadata_bytes, 0}}} =
             Saxy.parse_string(
               "<feed><entry/></feed>",
               Atom.handler(),
               Atom.new_parser_state(sink, max_feed_metadata_bytes: 0)
             )

    assert {:ok, %{error: {:resource_limit, :max_item_bytes, 0}}} =
             Saxy.parse_string(
               "<feed><entry/></feed>",
               Atom.handler(),
               Atom.new_parser_state(sink, max_item_bytes: 0)
             )
  end

  test "preserves relative links when no absolute feed base is available" do
    raw = %{"title" => "Story", "link" => [%{"href" => "/story", "rel" => "alternate"}]}

    assert {:ok, %Item{canonical_url: "/story"}} =
             Atom.normalize_item(raw, %Feed{html_url: "/"}, [])

    assert {:ok, %Item{canonical_url: "https://example.com/story"}} =
             Atom.normalize_item(
               raw,
               %Feed{html_url: "/", feed_url: "https://example.com/feed.xml"},
               []
             )
  end

  test "ignores unsupported Atom item media candidates" do
    candidates = %Media.CandidateSequence{
      positions: [0],
      values: %{0 => %Media.Candidate{name: {nil, "other"}}}
    }

    assert {:ok, %Item{media: []}} = Atom.normalize_item_result(%{}, candidates, %Feed{}, [])
  end

  test "joins multiple author names in source order" do
    raw = %{
      "title" => "Story",
      "author" => [" Alice ", %{"name" => "Bob"}, %{"email" => "ignored"}]
    }

    assert {:ok, %Item{author: "Alice, Bob"}} = Atom.normalize_item(raw, %Feed{}, [])
  end

  test "emits fallback feed metadata for an entry without a parent feed" do
    sink = fn event -> send(self(), event) end

    assert {:ok, _state} =
             Saxy.parse_string(
               "<entry><title>Orphan</title></entry>",
               Atom.handler(),
               Atom.new_parser_state(sink, [])
             )

    assert_receive {:feed, %Feed{type: :atom, title: nil}}
    assert_receive {:item, %Item{title: "Orphan"}}
  end

  test "ignores feed elements outside the document root" do
    sink = fn event -> send(self(), event) end

    assert {:ok, _state} =
             Saxy.parse_string(
               "<wrapper><feed/></wrapper>",
               Atom.handler(),
               Atom.new_parser_state(sink, [])
             )

    refute_receive {:feed, _}
    refute_receive {:item, _}
  end

  test "accounts for parser failures and closes empty feeds" do
    handler = Atom.handler()
    sink = fn event -> send(self(), event) end
    limited = Atom.new_parser_state(fn _ -> :ok end, max_xml_events: 0)

    assert {:stop, %{error: {:resource_limit, :max_xml_events, 0}}} =
             handler.handle_event(:start_document, [], limited)

    assert {:stop, %{error: {:resource_limit, :max_xml_events, 0}}} =
             handler.handle_event(:end_element, "feed", limited)

    empty = Atom.new_parser_state(fn _ -> :ok end, [])

    assert {:stop, %{error: :invalid_sax_event}} =
             handler.handle_event(:characters, "text", empty)

    assert {:stop, %{error: :invalid_sax_event}} =
             handler.handle_event(:end_element, "feed", %{
               empty
               | limits: %{empty.limits | depth: 1}
             })

    frame = %{name: "entry", attrs: %{}, children: %{}, text: "", markup: []}

    limited_item = %{
      empty
      | limits: %{empty.limits | scope: :item, max_item_bytes: 0},
        frames: [frame]
    }

    assert {:stop, %{error: {:resource_limit, :max_item_bytes, 0}}} =
             handler.handle_event(:characters, "x", limited_item)

    state = Atom.new_parser_state(fn _ -> :ok end, max_item_bytes: 1)
    assert {:ok, state} = handler.handle_event(:start_element, {"feed", []}, state)

    assert {:stop, %{error: {:resource_limit, :max_item_bytes, 1}}} =
             handler.handle_event(:start_element, {"entry", []}, state)

    assert {:halt, _, _} = Saxy.parse_string("<feed/>", handler, Atom.new_parser_state(sink, []))
    assert_receive {:feed, %Feed{type: :atom}}

    assert {:ok, _} =
             Saxy.parse_string("<other/>", handler, Atom.new_parser_state(fn _ -> :ok end, []))
  end

  defp parse(xml, opts \\ []),
    do: Saxy.parse_string(xml, Atom.handler(), Atom.new_parser_state(&send(self(), &1), opts))

  defp write_temp(contents) do
    path =
      Path.join(System.tmp_dir!(), "feed-reader-atom-#{System.unique_integer([:positive])}.xml")

    File.write!(path, contents)
    path
  end
end
