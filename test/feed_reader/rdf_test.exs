defmodule FeedReader.RDFTest do
  use ExUnit.Case, async: true

  alias FeedReader.{Feed, Formats.RDF, Item}

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
    assert {:ok, _} = parse(@xml, sink)

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

    assert {:ok, _} = parse("<rdf:RDF><item><title>Orphan</title></item></rdf:RDF>", sink)
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
end
