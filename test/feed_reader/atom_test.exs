defmodule FeedReader.AtomTest do
  use ExUnit.Case, async: true
  alias FeedReader.{Feed, Formats.Atom, Item}

  @xml ~s(<feed xmlns="http://www.w3.org/2005/Atom"><title>News</title><subtitle>Updates</subtitle><link rel="alternate" href="https://example.com/"/><category term="Tech"/><entry><title>Story</title><id>tag:example.com,2025:1</id><link href="/story"/><author><name>Writer</name></author><published>2025-02-24T17:00:05Z</published><content type="html">&lt;p&gt;Full text&lt;/p&gt;</content><summary>Brief</summary></entry></feed>)
  @xhtml ~s(<feed><title>Feed</title><id>https://example.com/fallback</id><entry><content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Hello <b>world</b></p></div></content></entry><entry><title>12345</title><link href="https://example.com/item"/><published>not a date</published></entry></feed>)

  test "normalizes feed metadata and entry fields" do
    assert {:ok, _} = parse(@xml)
    assert_receive {:feed, %Feed{title: "News", type: :atom, categories: ["Tech"]}}

    assert_receive {:item, %Item{content_full: "<p>Full text</p>"}}
    assert %Feed{html_url: nil} = Atom.normalize_feed(%{feed: %{}}, [])

    assert {:ok, _} = parse(@xhtml)

    assert_receive {:feed, %Feed{html_url: "https://example.com/fallback"}}
    assert_receive {:item, %Item{content_full: xhtml, content_summary: nil}}
    assert xhtml == "<div xmlns=\"http://www.w3.org/1999/xhtml\"><p>Hello <b>world</b></p></div>"
    assert_receive {:item, %Item{title: "12345", content_summary: "12345"}}
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

    assert {:ok, _} = Saxy.parse_string("<feed/>", handler, Atom.new_parser_state(sink, []))
    assert_receive {:feed, %Feed{type: :atom}}

    assert {:ok, _} =
             Saxy.parse_string("<other/>", handler, Atom.new_parser_state(fn _ -> :ok end, []))
  end

  defp parse(xml),
    do: Saxy.parse_string(xml, Atom.handler(), Atom.new_parser_state(&send(self(), &1), []))
end
