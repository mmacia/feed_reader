# Custom formats and transports

FeedReader supports custom format modules and injectable HTTP transports. Supply
them per call or configure stable defaults for the application.

## Format detection and selection

Built-in formats are tried in RSS, Atom, RDF order. Additional modules passed
through `:formats` are checked afterward, in list order. Duplicate modules are
removed. Format detection inspects at most `:max_detection_bytes` (65,536 by
default), so custom `matches_prefix?/1` callbacks must decide from that prefix
alone.

Atom detection checks the document root and Atom namespace (and supports the
legacy namespace-less `<feed>` form), so nested or foreign `feed` elements do
not claim a document. A namespaced Atom root also prevents an earlier RSS
substring signature from taking priority; RSS retains its existing priority for
legacy namespace-less signature collisions and other roots.

Automatic RDF detection requires a complete root start tag bound to the RDF
namespace; the conventional undeclared `<rdf:RDF>` root remains supported.
Wrong bindings, nested RDF tags, and cut-off root tags return `:unknown`. A
parsing call with `format: :rdf` bypasses automatic format selection, but the
RDF handler still applies its namespace-aware parsing rules. `FeedReader.validate/3`
checks only the explicitly selected format's bounded prefix signature.

Select a built-in by ID or module:

```elixir
FeedReader.parse_file("path/to/feed.xml", format: :rss, max_items: 500)
FeedReader.stream_file("path/to/feed.xml", format: FeedReader.Formats.RSS)
```

## Implement a format

Implement `FeedReader.Format` and provide a Saxy handler:

```elixir
defmodule MyApp.NoticeFormat do
  @behaviour FeedReader.Format
  alias FeedReader.{Feed, Item}

  @impl true
  def id, do: :notice

  @impl true
  def matches_prefix?(prefix), do: String.starts_with?(prefix, "<notice-feed")

  @impl true
  def handler, do: MyApp.NoticeHandler

  @impl true
  def new_parser_state(event_sink, opts) do
    %{event_sink: event_sink, opts: opts, frames: [], title: nil}
  end

  @impl true
  def normalize_feed(state, _opts) do
    %Feed{title: state.title}
  end

  @impl true
  def normalize_item(raw_item, _feed, _opts) do
    {:ok, %Item{uuid: raw_item["id"], title: raw_item["title"]}}
  end
end
```

The example shows the format callbacks; `MyApp.NoticeHandler` must implement
`Saxy.Handler`, parse the custom XML shape, put the parsed title into
`state.title`, call the supplied event sink with `{:feed, feed}` before item
events, and use the format's normalization callbacks to produce
`FeedReader.Feed` and `FeedReader.Item` values. A custom handler owns the XML
state and decides when complete raw items are ready to normalize and emit.

Register the module for automatic detection or resolve it by ID:

```elixir
FeedReader.stream_file("priv/notices.xml", formats: [MyApp.NoticeFormat])

FeedReader.stream_file("priv/notices.xml",
  format: :notice,
  formats: [MyApp.NoticeFormat]
)
```

The shared parser resource-limit options are passed to custom format callbacks.
Formats may define extra options of their own. See `FeedReader.Format` for the
full callback contract.

## Add an HTTP transport

Implement `FeedReader.Transport` and pass the module with `:http_client`:

```elixir
defmodule MyApp.FeedTransport do
  @behaviour FeedReader.Transport

  @impl true
  def request(url, opts) do
    request_options =
      opts
      |> Keyword.get(:http_options, [])
      |> Keyword.put_new(:receive_timeout, Keyword.get(opts, :feed_transport_timeout, 15_000))
      |> Keyword.put(:into, :self)
      |> Keyword.put(:raw, true)
      |> Keyword.put(:decode_body, false)
      |> Keyword.put(:compressed, false)
      |> Keyword.put(:max_redirects, 5)

    case Req.run([url: url], request_options) do
      {request, %Req.Response{} = response} ->
        {:ok,
         %{
           status: response.status,
           headers: Req.get_headers_list(response),
           final_url: URI.to_string(request.url),
           body: if(response.status == 304, do: [], else: response.body)
         }}

      {_request, error} ->
        {:error, error}
    end
  end
end

FeedReader.fetch_and_parse(url,
  max_items: 500
)
```

Configure the custom format, transport, and transport-specific timeout in
`config/config.exs`:

```elixir
config :feed_reader, :options,
  formats: [MyApp.NoticeFormat],
  http_client: MyApp.FeedTransport,
  feed_transport_timeout: 10_000
```

Per-call options take precedence over application options. A per-call
`:formats` list replaces the configured list; built-in formats are still tried
first. `:http_client` selects the `FeedReader.Transport` implementation. The
selected module receives the complete option list, including `:http_client` and
`:feed_transport_timeout`. `:http_options` is a separate list of Req request
options; in this example, `:feed_transport_timeout` supplies the Req
`:receive_timeout` unless `:http_options` already sets it.

The response map requires `:status`, `:headers`, `:final_url`, and `:body`.
`body` must be an enumerable of binary chunks. Return the response body without
decompressing it: the downloader performs decoding, size accounting, and
checksumming. Preserve redirects in `:final_url`. A 304 response should have an
empty body and is mapped to `:not_modified`.

The full options list is passed to the custom transport. The downloader itself
consumes `:previous_checksum` and download-limit options; other options are
available to the transport. The default `FeedReader.ReqTransport` recognizes
`:http_options`, `:previous_etag`, `:http_retry_attempts`, and `:retry_delay`.

## Default HTTP behavior

The default transport requests streamed raw bodies and disables automatic
decompression. It supports conditional ETags through `:previous_etag`, retries
selected server statuses and most transport errors, and follows at most five
redirects. TLS alerts and redirect failures are terminal. Gzip and deflate are
decoded downstream; unknown and stacked content encodings are rejected.

`:http_options` are forwarded to Req, but the transport enforces its raw
streaming, decompression, retry, and redirect settings. A supplied `:headers`
list replaces the default user-agent and accepted-encoding headers. See
`FeedReader.Transport` and `FeedReader.ReqTransport` for details.
