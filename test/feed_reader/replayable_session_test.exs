defmodule FeedReader.ReplayableSessionTest do
  use ExUnit.Case, async: false

  alias FeedReader.{Feed, Fetch, Item, Session}

  @url "https://example.com/feed.xml"
  @final_url "https://example.com/final.xml"

  @xml ~s(<rss version="2.0"><channel><title>Replayable</title><item><title>First</title><guid>one</guid></item><item><title>Second</title><guid>two</guid></item></channel></rss>)
  @relative_xml ~s(<rss version="2.0"><channel><title>Relative</title><item><title>First</title><link>/posts/one</link></item></channel></rss>)

  test "retains a replayable session file and replays from the beginning" do
    assert {:ok, %Session{fetch: %Fetch{}, events: events, resource: %{path: path}} = session} =
             stream(replayable: true)

    assert File.exists?(path)

    sample =
      events
      |> Stream.filter(&match?({:item, _}, &1))
      |> Enum.take(1)

    assert [{:item, %Item{uuid: "one"}}] = sample
    assert File.exists?(path)

    assert [
             {:feed, %Feed{title: "Replayable", feed_url: @final_url}},
             {:item, %Item{uuid: "one"}},
             {:item, %Item{uuid: "two"}}
           ] = Enum.to_list(events)

    assert File.exists?(path)
    assert_received {:transport_request, @url}
    refute_received {:transport_request, _}

    assert :ok = FeedReader.close(session)
    refute File.exists?(path)
    assert :ok = FeedReader.close(session)
  end

  test "stopping a sample pass keeps the file for a later replay" do
    assert {:ok, %Session{events: events, resource: %{path: path}} = session} =
             stream(replayable: true)

    on_exit(fn -> File.rm(path) end)

    assert [{:feed, %Feed{title: "Replayable"}}] =
             events |> Stream.take(1) |> Enum.to_list()

    assert File.exists?(path)

    assert [{:item, %Item{uuid: "one"}}] =
             events
             |> Stream.filter(&match?({:item, _}, &1))
             |> Enum.take(1)

    assert File.exists?(path)
    assert :ok = FeedReader.close(session)
    refute File.exists?(path)
  end

  test "resolves root-relative item URLs against the final response URL" do
    final_url = "https://cdn.example.net/feeds/final.xml"

    assert {:ok,
            %Session{
              events: events,
              fetch: %Fetch{final_url: ^final_url},
              resource: %{path: path}
            } = session} =
             stream(
               replayable: true,
               response: response([@relative_xml], [], 200, final_url)
             )

    on_exit(fn -> File.rm(path) end)

    assert [
             {:feed, %Feed{feed_url: ^final_url}},
             {:item, %Item{canonical_url: "https://cdn.example.net/posts/one"}}
           ] = Enum.to_list(events)

    assert :ok = FeedReader.close(session)
  end

  test "delivers parse errors only during enumeration and remains closable" do
    xml =
      ~s(<rss version="2.0"><channel><title>Broken</title><item><title>First</title></channel></rss>)

    assert {:ok, %Session{events: events, resource: %{path: path}} = session} =
             stream(replayable: true, response: response([xml], []))

    on_exit(fn -> File.rm(path) end)
    assert File.exists?(path)

    consumed = Enum.to_list(events)
    assert {:feed, %Feed{title: "Broken"}} = hd(consumed)
    assert {:error, %Saxy.ParseError{}} = List.last(consumed)
    assert File.exists?(path)

    assert :ok = FeedReader.close(session)
    refute File.exists?(path)
    assert :ok = FeedReader.close(session)
  end

  test "close is idempotent and leaves unrelated caller-owned files alone" do
    unrelated = local_path("caller-owned")
    File.write!(unrelated, "caller-owned")
    on_exit(fn -> File.rm(unrelated) end)

    assert {:ok, %Session{resource: %{path: path}} = session} = stream(replayable: true)
    on_exit(fn -> File.rm(path) end)

    assert :ok = FeedReader.close(session)
    assert :ok = FeedReader.close(session)
    refute File.exists?(path)
    assert File.read!(unrelated) == "caller-owned"
  end

  test "local file sessions are re-enumerable and ignore replayable" do
    path = local_path("local")
    File.write!(path, @xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %Session{fetch: nil, events: events}} =
             FeedReader.stream_file(path, replayable: true)

    assert [
             {:feed, %Feed{title: "Replayable"}},
             {:item, %Item{uuid: "one"}},
             {:item, %Item{uuid: "two"}}
           ] = Enum.to_list(events)

    assert [
             {:feed, %Feed{title: "Replayable"}},
             {:item, %Item{uuid: "one"}},
             {:item, %Item{uuid: "two"}}
           ] = Enum.to_list(events)

    assert File.read!(path) == @xml
  end

  test "default remote sessions still remove their file after enumeration" do
    assert {:ok, %Session{events: events, resource: %{path: path}}} = stream([])

    assert File.exists?(path)
    assert [{:feed, _feed}, {:item, _first}, {:item, _second}] = Enum.to_list(events)
    refute File.exists?(path)
  end

  test "only true enables replay; other values keep automatic cleanup" do
    for value <- [false, nil, :yes] do
      assert {:ok, %Session{events: events, resource: %{path: path}}} =
               stream(replayable: value)

      assert [{:feed, _feed} | _items] = Enum.to_list(events)
      refute File.exists?(path)
    end
  end

  test "replayable verified sessions retain and replay their file" do
    assert {:ok, %Session{fetch: %Fetch{}, events: events, resource: %{path: path}} = session} =
             stream_verified(replayable: true)

    assert [{:feed, %Feed{title: "Replayable"}}] =
             events |> Stream.take(1) |> Enum.to_list()

    assert File.exists?(path)

    assert [
             {:feed, %Feed{feed_url: @final_url}},
             {:item, %Item{uuid: "one"}},
             {:item, %Item{uuid: "two"}}
           ] = Enum.to_list(events)

    assert File.exists?(path)
    assert_received {:transport_request, @url}
    refute_received {:transport_request, _}

    assert :ok = FeedReader.close(session)
    refute File.exists?(path)
  end

  test "forwards previous_etag for replayable requests" do
    assert {:ok, %Session{} = session} =
             stream(replayable: true, previous_etag: "\"v1\"")

    assert_received {:transport_request_options, opts}
    assert opts[:previous_etag] == "\"v1\""

    assert :ok = FeedReader.close(session)
  end

  test "replayable requests return unchanged outcomes without a session or file" do
    before = download_files()

    assert {:ok, :not_modified} =
             stream(replayable: true, response: response([], [], 304))

    assert {:ok, :not_changed} =
             stream(replayable: true, previous_checksum: checksum(@xml))

    assert download_files() == before
  end

  test "a changed body still returns a usable replayable session" do
    assert {:ok, %Session{events: events, resource: %{path: path}} = session} =
             stream(replayable: true, previous_checksum: checksum("stale body"))

    assert File.read!(path) == @xml

    assert [{:feed, _feed}, {:item, _first}, {:item, _second}] = Enum.to_list(events)
    assert File.exists?(path)

    assert :ok = FeedReader.close(session)
    refute File.exists?(path)
  end

  test "replayable requests preserve failures and remove partial files" do
    before = download_files()

    assert {:error, {:http_status, 418}} =
             stream(replayable: true, response: response([], [], 418))

    assert {:error, :offline} =
             stream(replayable: true, request_result: {:error, :offline})

    assert {:error, {:resource_limit, :max_compressed_bytes, 2}} =
             stream(replayable: true, max_compressed_bytes: 2)

    assert download_files() == before
  end

  test "replayable requests remove the file when the feed is rejected" do
    before = download_files()

    assert {:error, :unknown} = stream(replayable: true, format: :unsupported)
    assert download_files() == before

    assert {:error, :unknown} = stream_verified(replayable: true, format: :unsupported)
    assert download_files() == before
  end

  defp stream(opts) do
    FeedReader.stream(@url, request_opts(opts))
  end

  defp stream_verified(opts) do
    FeedReader.stream_verified(@url, request_opts(opts))
  end

  defp request_opts(opts) do
    response = Keyword.get(opts, :response, response([@xml], [{"ETag", "\"v1\""}]))

    [
      http_client: FeedReader.TestSupport.TransportClient,
      response: response,
      test_pid: self()
    ] ++ Keyword.delete(opts, :response)
  end

  defp response(body, headers, status \\ 200, final_url \\ @final_url) do
    %{status: status, headers: headers, final_url: final_url, body: body}
  end

  defp checksum(payload), do: Base.encode16(:crypto.hash(:md5, payload), case: :lower)

  defp local_path(label) do
    Path.join(
      System.tmp_dir!(),
      "feed_reader-#{label}-#{System.unique_integer([:positive])}.xml"
    )
  end

  defp download_files do
    System.tmp_dir!()
    |> Path.join("feed_reader-download-*.xml")
    |> Path.wildcard()
  end
end
