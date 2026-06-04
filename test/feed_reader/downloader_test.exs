defmodule FeedReader.DownloaderTest do
  use ExUnit.Case, async: false

  alias FeedReader.Downloader

  test "downloads decoded bytes, computes a lowercase MD5, and releases its file" do
    payload = "<rss>feed</rss>"
    response = response([payload], [{"ETag", "\"v1\""}, {"content-encoding", "identity"}])

    assert {:ok, %{path: path, fetch: fetch}} = download(response, max_decoded_bytes: :invalid)
    assert File.read!(path) == payload
    assert fetch.checksum == Base.encode16(:crypto.hash(:md5, payload), case: :lower)
    assert fetch.etag == "\"v1\""
    assert fetch.status == 200
    assert fetch.final_url == "https://example.com/final.xml"
    assert :ok = Downloader.close(%{path: path})
    refute File.exists?(path)
    assert :ok = Downloader.close(%{path: path})
  end

  test "decompresses gzip before writing and checksumming" do
    payload = "<rss><channel><title>feed</title></channel></rss>"
    compressed = :zlib.gzip(payload)
    midpoint = div(byte_size(compressed), 2)

    chunks = [
      binary_part(compressed, 0, midpoint),
      binary_part(compressed, midpoint, byte_size(compressed) - midpoint)
    ]

    response = response(chunks, [{"content-encoding", "gzip"}])

    assert {:ok, %{path: path, fetch: fetch}} = download(response)
    assert File.read!(path) == payload
    assert fetch.checksum == Base.encode16(:crypto.hash(:md5, payload), case: :lower)
    Downloader.close(%{path: path})
  end

  test "decompresses raw deflate content" do
    payload = "<rss>deflate</rss>"
    compressed = deflate(payload)

    assert {:ok, %{path: path, fetch: fetch}} =
             download(response([compressed], [{"content-encoding", "deflate"}]))

    assert File.read!(path) == payload
    assert fetch.checksum == checksum(payload)
    Downloader.close(%{path: path})
  end

  test "maps 304 without creating a temporary file" do
    before = download_files()
    assert {:ok, :not_modified} = download(response([], [], 304))
    assert download_files() == before
  end

  test "returns not changed after checksum and removes the temporary file" do
    payload = "unchanged"
    before = download_files()

    assert {:ok, :not_changed} =
             download(response([payload], []), previous_checksum: checksum(payload))

    assert download_files() == before
  end

  test "enforces compressed and decoded byte limits and cleans failed downloads" do
    before = download_files()

    assert {:error, {:resource_limit, :max_compressed_bytes, 2}} =
             download(response(["long"], []), max_compressed_bytes: 2)

    assert {:error, {:resource_limit, :max_decoded_bytes, 2}} =
             download(response(["long"], []), max_decoded_bytes: 2)

    assert {:error, {:resource_limit, :max_temp_bytes, 2}} =
             download(response(["long"], []), max_temp_bytes: 2)

    compressed = :zlib.gzip(String.duplicate("a", 100))

    assert {:error, {:resource_limit, :max_expansion_ratio, 1}} =
             download(response([compressed], [{"content-encoding", "gzip"}]),
               max_expansion_ratio: 1
             )

    assert download_files() == before
  end

  test "returns stable errors for invalid URLs, statuses, transport errors, and chunks" do
    assert {:error, :invalid_url} = Downloader.download(:invalid, [])
    assert {:error, {:http_status, 418}} = download(response([], [], 418))
    assert {:error, :offline} = download(response([], []), request_result: {:error, :offline})
    assert {:error, :invalid_chunk} = download(response([:not_binary], []))
  end

  test "rejects unknown encodings and malformed compressed bodies, cleaning temp files" do
    before = download_files()

    assert {:error, :unsupported_content_encoding} =
             download(response(["body"], [{"content-encoding", "br, gzip"}]))

    assert {:error, :invalid_compressed_body} =
             download(response(["not gzip"], [{"content-encoding", "gzip"}]))

    assert download_files() == before
  end

  test "converts exceptions while enumerating response chunks to download errors" do
    before = download_files()
    chunks = Stream.map(["chunk"], fn _chunk -> raise "chunk read failed" end)

    assert {:error, {:download_failed, %RuntimeError{message: "chunk read failed"}}} =
             download(response(chunks, []))

    assert download_files() == before
  end

  defp download(response, opts \\ []) do
    Downloader.download(
      "https://example.com/feed.xml",
      [
        http_client: FeedReader.TestSupport.TransportClient,
        response: response,
        test_pid: self()
      ] ++
        opts
    )
  end

  defp response(body, headers, status \\ 200) do
    %{status: status, headers: headers, final_url: "https://example.com/final.xml", body: body}
  end

  defp checksum(payload), do: Base.encode16(:crypto.hash(:md5, payload), case: :lower)

  defp deflate(payload) do
    zlib = :zlib.open()
    :ok = :zlib.deflateInit(zlib, :default, :deflated, -15, 8, :default)
    compressed = :zlib.deflate(zlib, payload, :finish) |> IO.iodata_to_binary()
    :ok = :zlib.deflateEnd(zlib)
    :zlib.close(zlib)
    compressed
  end

  defp download_files do
    System.tmp_dir!()
    |> Path.join("feed_reader-download-*.xml")
    |> Path.wildcard()
  end
end
