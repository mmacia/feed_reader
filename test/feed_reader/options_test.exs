defmodule FeedReader.OptionsTest do
  use ExUnit.Case, async: false

  alias FeedReader.TestSupport.ExternalFormat

  @xml ~s(<rss version="2.0"><channel><title>Example</title><item><title>First</title></item><item><title>Second</title></item></channel></rss>)

  setup do
    previous = Application.fetch_env(:feed_reader, :options)

    on_exit(fn ->
      case previous do
        {:ok, options} -> Application.put_env(:feed_reader, :options, options)
        :error -> Application.delete_env(:feed_reader, :options)
      end
    end)
  end

  test "application defaults apply locally and call options take precedence" do
    Application.put_env(:feed_reader, :options, max_items: 1)
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{items: [_item], item_limit_reached?: true}} = FeedReader.parse_binary(@xml)
    assert {:ok, %{items: items}} = FeedReader.parse_binary(@xml, max_items: 2)
    assert length(items) == 2
    assert {:ok, %{items: [_item], item_limit_reached?: true}} = FeedReader.parse_stream([@xml])
    assert {:ok, %{items: [_item], item_limit_reached?: true}} = FeedReader.parse_file(path)
    assert {:ok, %{items: items}} = FeedReader.parse_file(path, max_items: 2)
    assert length(items) == 2
  end

  test "configured formats are replaceable and built-ins remain available" do
    Application.put_env(:feed_reader, :options, formats: [ExternalFormat])

    assert FeedReader.detect_format("<external-feed/>") == :external_test
    assert FeedReader.detect_format("<external-feed/>", formats: []) == :unknown
    assert FeedReader.detect_format("<rss version='2.0'>") == :rss
    assert FeedReader.validate("<external-feed/>", :external_test)

    path = write_temp("<external-feed/>")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} =
             FeedReader.stream_file(path, format: :external_test, emit_event: true)

    assert {:feed, %{title: "External"}} = hd(Enum.to_list(events))

    assert {:ok, %{events: events}} =
             FeedReader.stream_file_verified(path, format: :external_test, emit_event: true)

    assert {:feed, %{title: "External"}} = hd(Enum.to_list(events))

    assert {:ok, %{feed: %{title: "External"}}} =
             FeedReader.parse_file(path, format: :external_test, emit_event: true, max_items: 1)
  end

  test "configured parsing limits apply unless overridden" do
    Application.put_env(:feed_reader, :options, max_queue_bytes: 1)
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} = FeedReader.stream_file(path)
    assert [{:error, {:resource_limit, :max_queue_bytes, 1}}] = Enum.to_list(events)

    assert {:ok, %{events: events}} =
             FeedReader.stream_file(path, max_queue_bytes: 1_000_000)

    assert {:feed, _feed} = hd(Enum.to_list(events))
  end

  test "request-specific options remain call-level only" do
    Application.put_env(:feed_reader, :options,
      max_items: 2,
      item_filter: fn _item -> false end,
      feed_url: "https://configured.example/feed"
    )

    assert {:ok, %{items: items}} = FeedReader.parse_binary(@xml)
    assert length(items) == 2
  end

  test "malformed application options are ignored" do
    Application.put_env(:feed_reader, :options, :invalid)

    assert FeedReader.detect_format("<rss version='2.0'>") == :rss
    assert {:ok, %{items: items, item_limit_reached?: false}} = FeedReader.parse_binary(@xml)
    assert length(items) == 2
  end

  test "remote APIs use configured transport options and allow call overrides" do
    Application.put_env(:feed_reader, :options,
      http_client: FeedReader.TestSupport.TransportClient,
      http_options: [request_tag: :configured],
      http_retry_attempts: 4,
      retry_delay: 20,
      test_pid: self(),
      response: response(@xml)
    )

    assert {:ok, session} = FeedReader.stream("https://example.com/feed")
    assert_receive {:transport_request_options, opts}
    assert opts[:http_options] == [request_tag: :configured]
    assert opts[:http_retry_attempts] == 4
    assert opts[:retry_delay] == 20
    assert :ok = FeedReader.close(session)

    assert {:ok, verified} =
             FeedReader.stream_verified("https://example.com/feed", http_retry_attempts: 0)

    assert_receive {:transport_request_options, opts}
    assert opts[:http_retry_attempts] == 0
    assert :ok = FeedReader.close(verified)
  end

  test "remote APIs pass configured retry counts to the Req transport" do
    Application.put_env(:feed_reader, :options,
      http_options: [plug: {Req.Test, __MODULE__}],
      http_retry_attempts: 1
    )

    Req.Test.expect(__MODULE__, 2, fn conn -> Plug.Conn.send_resp(conn, 500, "error") end)

    assert {:error, :internal_server_error} = FeedReader.stream("https://example.com/feed")
  end

  test "remote download and collection limits use configured defaults and call overrides" do
    Application.put_env(:feed_reader, :options,
      http_client: FeedReader.TestSupport.TransportClient,
      max_compressed_bytes: 1,
      max_items: 1,
      test_pid: self(),
      response: response(@xml)
    )

    assert {:error, {:resource_limit, :max_compressed_bytes, 1}} =
             FeedReader.stream("https://example.com/feed")

    assert {:ok, session} =
             FeedReader.stream("https://example.com/feed", max_compressed_bytes: 10_000)

    assert :ok = FeedReader.close(session)

    Application.put_env(:feed_reader, :options,
      http_client: FeedReader.TestSupport.TransportClient,
      max_items: 1,
      test_pid: self(),
      response: response(@xml)
    )

    assert {:ok, %{items: [_item], item_limit_reached?: true}} =
             FeedReader.fetch_and_parse("https://example.com/feed")

    assert {:ok, %{items: items}} =
             FeedReader.fetch_and_parse("https://example.com/feed", max_items: 2)

    assert length(items) == 2
  end

  defp response(xml),
    do: %{
      status: 200,
      headers: [],
      final_url: "https://example.com/final.xml",
      body: [xml]
    }

  defp write_temp(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "feed_reader-options-#{System.unique_integer([:positive])}.xml"
      )

    File.write!(path, content)
    path
  end
end
