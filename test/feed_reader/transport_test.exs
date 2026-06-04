defmodule FeedReader.TransportTest do
  use ExUnit.Case, async: false

  alias FeedReader.{ReqTransport, Transport}

  setup do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "body") end)
    :ok
  end

  test "dispatches through an injectable client" do
    assert {:ok, %{body: ["test"]}} =
             Transport.request("https://example.com/feed",
               http_client: FeedReader.TestSupport.TransportClient,
               test_pid: self()
             )

    assert_receive {:transport_request, "https://example.com/feed"}
  end

  test "uses the default Req client when no client is injected" do
    assert {:error, :invalid_url} = Transport.request(123)
  end

  test "passes an invalid option list through to the default client" do
    assert {:error, :invalid_url} = Transport.request(:invalid, invalid: true)
  end

  test "rejects an invalid URL through the direct default client" do
    assert {:error, :invalid_url} = ReqTransport.request(123)
  end

  test "returns a lazy raw response with headers and the final URL" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "user-agent") == ["feedex/1"]
      assert Plug.Conn.get_req_header(conn, "accept-encoding") == ["gzip, deflate, identity"]
      Plug.Conn.send_resp(conn, 200, "body")
    end)

    assert {:ok, response} =
             ReqTransport.request("https://example.com/feed",
               http_options: [plug: {Req.Test, __MODULE__}]
             )

    assert response.status == 200
    assert response.final_url == "https://example.com/feed"
    assert Enum.join(response.body) == "body"
  end

  test "sends previous ETags verbatim and exposes a 304 response" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "if-none-match") == ["W/\"exact\""]
      Plug.Conn.send_resp(conn, 304, "")
    end)

    assert {:ok, %{status: 304, body: []}} =
             ReqTransport.request("https://example.com/feed",
               previous_etag: "W/\"exact\"",
               http_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "follows redirects and reports the final URL" do
    Req.Test.expect(__MODULE__, 2, fn conn ->
      case conn.request_path do
        "/redirect" ->
          Plug.Conn.put_resp_header(conn, "location", "/final") |> Plug.Conn.send_resp(302, "")

        "/final" ->
          Plug.Conn.send_resp(conn, 200, "body")
      end
    end)

    assert {:ok, %{final_url: "https://example.com/final"}} =
             ReqTransport.request("https://example.com/redirect",
               http_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "retries status 500 and maps the terminal status" do
    Req.Test.expect(__MODULE__, 3, fn conn -> Plug.Conn.send_resp(conn, 500, "error") end)

    assert {:error, :internal_server_error} =
             ReqTransport.request("https://example.com/feed",
               http_retry_attempts: 2,
               http_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "maps typed status errors without retrying" do
    for {status, reason} <- [{403, :forbidden}, {404, :not_found}, {429, :too_many_requests}] do
      Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, status, "error") end)

      assert {:error, ^reason} =
               ReqTransport.request("https://example.com/feed",
                 http_options: [plug: {Req.Test, __MODULE__}]
               )
    end
  end

  test "returns an error tuple for an unmapped status" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 418, "teapot") end)

    assert {:error, {:http_status, 418}} =
             ReqTransport.request("https://example.com/feed",
               http_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "retries transport failures" do
    Req.Test.expect(__MODULE__, 2, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, :econnrefused} =
             ReqTransport.request("https://example.com/feed",
               http_retry_attempts: 1,
               http_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "does not retry TLS alerts and returns the alert reason" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.transport_error(conn, {:tls_alert, {:handshake_failure, "bad certificate"}})
    end)

    assert {:error, :handshake_failure} =
             ReqTransport.request("https://example.com/feed",
               http_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "does not retry after the redirect limit" do
    Req.Test.expect(__MODULE__, 6, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "/loop")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, %Req.TooManyRedirectsError{max_redirects: 5}} =
             ReqTransport.request("https://example.com/loop",
               http_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "uses fallback values for invalid retry options" do
    Req.Test.expect(__MODULE__, 6, fn conn -> Plug.Conn.send_resp(conn, 500, "error") end)

    assert {:error, :internal_server_error} =
             ReqTransport.request("https://example.com/feed",
               http_retry_attempts: :invalid,
               retry_delay: :invalid,
               http_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "accepts a retry delay function" do
    Req.Test.expect(__MODULE__, 2, fn conn -> Plug.Conn.send_resp(conn, 500, "error") end)

    assert {:error, :internal_server_error} =
             ReqTransport.request("https://example.com/feed",
               http_retry_attempts: 1,
               retry_delay: fn _attempt -> 0 end,
               http_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "returns generic Req errors without retrying" do
    assert {:error, %Req.HTTPError{reason: :unexpected}} =
             ReqTransport.request("https://example.com/feed",
               http_options: [adapter: FeedReader.TestSupport.ReqErrorAdapter]
             )
  end

  test "returns redirect errors without retrying" do
    assert {:error, %Req.TooManyRedirectsError{max_redirects: 5}} =
             ReqTransport.request("https://example.com/feed",
               http_options: [adapter: FeedReader.TestSupport.RedirectErrorAdapter]
             )
  end
end
