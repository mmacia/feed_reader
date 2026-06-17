defmodule FeedReader.VerifiedParserTest do
  use ExUnit.Case, async: false

  alias FeedReader.{Feed, Fetch, Item, Session}

  @xml ~s(<rss version="2.0"><channel><title>Verified</title><item><title>One</title></item></channel></rss>)

  test "validates before returning a local event stream" do
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %Session{fetch: nil, resource: nil, events: events}} =
             FeedReader.stream_file_verified(path, max_parse_passes: 0)

    assert [{:feed, %Feed{title: "Verified"}}, {:item, %Item{title: "One"}}] =
             Enum.to_list(events)

    assert File.read!(path) == @xml
  end

  test "does not return a session for malformed tails or an insufficient pass budget" do
    path = write_temp(@xml <> "<broken")
    on_exit(fn -> File.rm(path) end)

    assert {:error, %Saxy.ParseError{}} = FeedReader.stream_file_verified(path)

    valid_path = write_temp(@xml)
    on_exit(fn -> File.rm(valid_path) end)

    assert {:error, {:resource_limit, :max_parse_passes, 1}} =
             FeedReader.stream_file_verified(valid_path, max_parse_passes: 1)
  end

  test "releases a remote verified source after enumeration or explicit close" do
    assert {:ok, %Session{fetch: %Fetch{}, resource: %{path: path}} = session} =
             FeedReader.stream_verified("https://example.com/feed.xml", remote_options())

    assert [{:feed, %Feed{}}, {:item, %Item{}}] = Enum.to_list(session.events)
    refute File.exists?(path)

    assert {:ok, %Session{resource: %{path: path2}} = session2} =
             FeedReader.stream_verified("https://example.com/feed.xml", remote_options())

    assert File.exists?(path2)
    assert :ok = FeedReader.close(session2)
    refute File.exists?(path2)
  end

  defp remote_options do
    [
      http_client: FeedReader.TestSupport.TransportClient,
      response: %{
        status: 200,
        headers: [],
        final_url: "https://example.com/final.xml",
        body: [@xml]
      },
      test_pid: self()
    ]
  end

  defp write_temp(xml) do
    path =
      Path.join(
        System.tmp_dir!(),
        "feed_reader-verified-#{System.unique_integer([:positive])}.xml"
      )

    File.write!(path, xml)
    path
  end
end
