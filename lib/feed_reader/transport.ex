defmodule FeedReader.Transport do
  @moduledoc """
  Injectable HTTP transport boundary used by remote feed operations.

  Implementations return raw response chunks as an enumerable. They must not
  automatically decompress the response: the downloader owns decompression,
  decoded-byte accounting, and checksums. `final_url` must include redirects;
  a 304 response has an empty body and is returned without downloading content.

  `request/2` receives the full option list passed to the remote downloader.
  The default `FeedReader.ReqTransport` recognizes these transport options:

  - `:http_client` — module implementing this behaviour, selected by
    `Transport.request/2`; defaults to `FeedReader.ReqTransport`. The selected
    module receives the full options list, including this option.
  - `:http_options` — Req request options forwarded to `Req.run/2`. The transport
    enforces streamed raw bodies, disables automatic decompression, and sets the
    retry and redirect options described below; redirects are limited to five.
    A custom `:headers` list replaces the defaults. Otherwise, headers default to
    `user-agent: feedex/1` and `accept-encoding: gzip, deflate, identity`.
  - `:previous_etag` — if binary, sent verbatim as `If-None-Match` on the
    GET request. It replaces any existing `If-None-Match` header. A 304 response
    returns `{:ok, response}` with `status: 304` and `body: []`; no HEAD request
    is made.
  - `:http_retry_attempts` — non-negative number of retries after the initial
    request; defaults to `5`. The Req transport retries status 400 and 500 and
    most transport errors. TLS alerts and redirect failures are terminal.
  - `:retry_delay` — non-negative delay in milliseconds or an arity-one Req
    retry-delay function; defaults to `0`. Invalid values use the default.

  The downloader also passes these recognized options through to custom
  transports, but consumes them itself rather than using them to configure HTTP:

  - `:previous_checksum` — decoded-body checksum used for the unchanged result.
  - `:max_compressed_bytes` — maximum total raw response bytes, default 50 MiB.
  - `:max_decoded_bytes` — maximum total decompressed bytes, default 50 MiB.
  - `:max_temp_bytes` — maximum bytes written to the owned temporary file,
    default 50 MiB.
  - `:max_expansion_ratio` — maximum decoded-to-compressed byte ratio, default
    `100`.

  Other options remain available to injected transport implementations.
  """

  @type response :: %{
          required(:status) => pos_integer(),
          required(:headers) => [{String.t(), String.t()}],
          required(:final_url) => String.t(),
          required(:body) => Enumerable.t()
        }

  @doc "Performs a GET and returns raw response chunks and response metadata."
  @callback request(url :: String.t(), opts :: keyword()) ::
              {:ok, response()} | {:error, term()}

  @doc "Dispatches the request to `:http_client`, or `FeedReader.ReqTransport` by default."
  @spec request(String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def request(url, opts \\ []) do
    client = Keyword.get(opts, :http_client, FeedReader.ReqTransport)
    client.request(url, opts)
  end
end
