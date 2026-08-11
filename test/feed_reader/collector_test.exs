defmodule FeedReader.CollectorTest do
  use ExUnit.Case, async: true

  alias FeedReader.{Feed, Item, ParseResult}

  @xml ~s(<rss version="2.0"><channel><title>Example</title><item><title>First</title><guid>one</guid></item><item><title>Second</title><guid>two</guid></item></channel></rss>)

  test "collects binary XML through the local event stream" do
    assert {:ok, %ParseResult{feed: %Feed{title: "Example"}, items: items}} =
             FeedReader.parse_binary(@xml, max_items: 2)

    assert [%Item{uuid: "one"}, %Item{uuid: "two"}] = items
  end

  test "collects chunk enumerables without requiring a path" do
    chunks = String.graphemes(@xml)

    assert {:ok, %ParseResult{items: [%Item{uuid: "one"}, %Item{uuid: "two"}]}} =
             FeedReader.parse_stream(chunks, max_items: 2)
  end

  test "collects caller-owned files and preserves them" do
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %ParseResult{items: items}} = FeedReader.parse_file(path, max_items: 2)
    assert length(items) == 2
    assert File.read!(path) == @xml
  end

  test "requires a positive max_items for every collector" do
    assert {:error, {:invalid_option, :max_items}} = FeedReader.parse_binary(@xml)
    assert {:error, {:invalid_option, :max_items}} = FeedReader.parse_file("missing.xml")
    assert {:error, {:invalid_option, :max_items}} = FeedReader.parse_stream([])
    assert {:error, {:invalid_option, :max_items}} = FeedReader.parse_binary(@xml, max_items: 0)
    assert {:error, {:invalid_option, :max_items}} = FeedReader.parse_stream([], max_items: :all)
  end

  test "propagates local source errors" do
    assert {:error, :enoent} = FeedReader.parse_file("/path/that/does/not/exist", max_items: 1)
  end

  test "filters before counting and collecting" do
    filter = fn %Item{uuid: uuid} -> uuid == "two" end

    assert {:ok, %ParseResult{items: [%Item{uuid: "two"}]}} =
             FeedReader.parse_binary(@xml, max_items: 1, item_filter: filter)
  end

  test "reports an item beyond the bound instead of returning a partial result" do
    assert {:error, {:max_items_exceeded, 1}} = FeedReader.parse_binary(@xml, max_items: 1)
  end

  test "ignores malformed content after the root element" do
    assert {:ok, %ParseResult{items: [%Item{uuid: "one"}, %Item{uuid: "two"}]}} =
             FeedReader.parse_binary(@xml <> "<broken", max_items: 2)
  end

  test "rejects non-whitespace content before the XML document" do
    assert {:error, _reason} = FeedReader.parse_binary("junk" <> @xml, max_items: 2)
  end

  test "rejects invalid chunks and binary arguments" do
    assert {:error, :invalid_chunk} =
             FeedReader.parse_stream([@xml, 123], max_items: 2)

    assert {:error, :invalid_binary} = FeedReader.parse_binary(123, max_items: 2)
  end

  test "returns an error for an invalid item filter" do
    path = write_temp("<external-feed/>")
    on_exit(fn -> File.rm(path) end)

    assert {:error, {:invalid_option, :item_filter}} =
             FeedReader.parse_file(path,
               format: :external_test,
               formats: [FeedReader.TestSupport.ExternalFormat],
               max_items: 1,
               item_filter: :not_a_function
             )
  end

  test "rejects collection without feed metadata" do
    path = write_temp("<external-feed/>")
    on_exit(fn -> File.rm(path) end)

    assert {:error, :feed_metadata_missing} =
             FeedReader.parse_file(path,
               format: :external_test,
               formats: [FeedReader.TestSupport.ExternalFormat],
               max_items: 1
             )
  end

  test "handles duplicate metadata, ignored events, and parser errors" do
    feed = %Feed{title: "Custom", type: :rss}
    item = %Item{uuid: "custom"}
    path = write_temp("<external-feed/>")
    on_exit(fn -> File.rm(path) end)

    opts = [
      format: :external_test,
      formats: [FeedReader.TestSupport.ExternalFormat],
      max_items: 1,
      collector_events: [{:feed, feed}, :ignored, {:item, item}, {:feed, feed}]
    ]

    assert {:ok, %ParseResult{feed: ^feed, items: [^item]}} = FeedReader.parse_file(path, opts)

    assert {:error, :custom_parser_error} =
             FeedReader.parse_file(
               path,
               Keyword.put(opts, :collector_events, [{:error, :custom_parser_error}])
             )
  end

  test "reports an enumerable failure and still cleans its temporary source" do
    chunks =
      Stream.resource(fn -> :ok end, fn _state -> raise "chunk failure" end, fn _ -> :ok end)

    assert {:error, {:stream_write_failed, %RuntimeError{message: "chunk failure"}}} =
             FeedReader.parse_stream(chunks, max_items: 1)
  end

  defp write_temp(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "feed_reader-collector-#{System.unique_integer([:positive])}.xml"
      )

    File.write!(path, content)
    path
  end
end
