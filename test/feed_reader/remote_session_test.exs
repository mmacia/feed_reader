defmodule FeedReader.RemoteSessionTest do
  use ExUnit.Case, async: false

  alias FeedReader.{Feed, Item, RemoteResult, Session}

  @xml ~s(<rss version="2.0"><channel><title>Remote</title><item><title>First</title><guid>one</guid></item><item><title>Second</title><guid>two</guid></item></channel></rss>)

  test "streams remote events with fetch metadata and removes the file after completion" do
    assert {:ok, %Session{fetch: fetch, events: events, resource: %{path: path}}} =
             stream(@xml)

    assert fetch.final_url == "https://example.com/final.xml"
    assert fetch.etag == "\"v1\""
    assert File.exists?(path)

    assert [
             {:feed, %Feed{title: "Remote", feed_url: "https://example.com/final.xml"}},
             {:item, %Item{uuid: "one"}},
             {:item, %Item{uuid: "two"}}
           ] = Enum.to_list(events)

    refute File.exists?(path)
  end

  test "closes an unstarted or partially consumed session idempotently" do
    assert {:ok, %Session{resource: %{path: path}} = session} = stream(@xml)
    assert :ok = FeedReader.close(session)
    assert :ok = FeedReader.close(session)
    refute File.exists?(path)

    assert {:ok, %Session{events: events2, resource: %{path: path2}}} = stream(@xml)
    assert [{:feed, %Feed{}}] = events2 |> Stream.take(1) |> Enum.to_list()
    refute File.exists?(path2)
  end

  test "collects remote feeds within the required finite item limit" do
    assert {:error, {:invalid_option, :max_items}} = fetch_and_parse(@xml, [])
    refute_received {:transport_request, _url}

    assert {:ok, %RemoteResult{feed: %Feed{title: "Remote"}, items: items, fetch: fetch}} =
             fetch_and_parse(@xml, max_items: 2)

    assert [%Item{uuid: "one"}, %Item{uuid: "two"}] = items
    assert fetch.status == 200

    before = download_files()
    assert {:error, {:max_items_exceeded, 1}} = fetch_and_parse(@xml, max_items: 1)
    assert download_files() == before

    assert {:error, _reason} = fetch_and_parse(@xml <> "<broken", max_items: 2)
    assert download_files() == before
  end

  test "returns unchanged outcomes without parsing and cleans invalid-format downloads" do
    assert {:ok, :not_modified} =
             fetch_and_parse("", max_items: 1, response: response([], [], 304))

    assert {:ok, :not_changed} =
             fetch_and_parse(@xml, max_items: 1, previous_checksum: checksum(@xml))

    before = download_files()
    assert {:error, :unknown} = stream("<unknown/>", format: :invalid_format)
    assert download_files() == before
  end

  test "verified downloads preserve unchanged outcomes and clean rejected feeds" do
    url = "https://example.com/feed.xml"

    assert {:ok, :not_modified} =
             FeedReader.stream_verified(url, request_opts("", response: response([], [], 304)))

    assert {:ok, :not_changed} =
             FeedReader.stream_verified(
               url,
               request_opts(@xml, previous_checksum: checksum(@xml))
             )

    before = download_files()

    assert {:error, :unknown} =
             FeedReader.stream_verified(url, request_opts("<unknown/>", format: :invalid))

    assert download_files() == before
  end

  test "verified stream validates its default-argument URL path" do
    assert {:error, :invalid_url} = FeedReader.stream_verified(:invalid)
  end

  test "covers default options and closing a local session" do
    assert {:error, :invalid_url} = FeedReader.stream(:invalid)

    assert {:error, {:invalid_option, :max_items}} =
             FeedReader.fetch_and_parse("https://example.com/feed.xml")

    assert :ok = FeedReader.close(%Session{})
  end

  defp stream(xml, opts \\ []) do
    FeedReader.stream("https://example.com/feed.xml", request_opts(xml, opts))
  end

  defp fetch_and_parse(xml, opts) do
    request = request_opts(xml, opts)
    FeedReader.fetch_and_parse("https://example.com/feed.xml", request)
  end

  defp request_opts(xml, opts) do
    response = Keyword.get(opts, :response, response([xml], [{"ETag", "\"v1\""}]))

    [
      http_client: FeedReader.TestSupport.TransportClient,
      response: response,
      test_pid: self()
    ] ++ Keyword.delete(opts, :response)
  end

  defp response(body, headers, status \\ 200),
    do: %{
      status: status,
      headers: headers,
      final_url: "https://example.com/final.xml",
      body: body
    }

  defp checksum(xml), do: Base.encode16(:crypto.hash(:md5, xml), case: :lower)

  defp download_files do
    Path.join(System.tmp_dir!(), "feed_reader-download-*.xml") |> Path.wildcard()
  end
end
