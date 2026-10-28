defmodule FeedReader do
  @moduledoc """
  Standalone feed fetching and parsing library.

  This module exposes format detection, validation, local parsing, and streaming
  helpers. Remote sessions download and checksum into a temporary file before
  exposing their one-pass event stream.

  ## Application configuration

  Configure stable defaults under `:feed_reader, :options`. Per-call options
  override configured values, which override the defaults below. The application
  value must be a keyword list; other values are ignored. `:feed_url`,
  `:previous_etag`, `:previous_checksum`, and `:item_filter` are request-specific
  and can only be supplied to individual calls. Options owned by custom formats
  or transports can also be configured and are passed to those integrations.

      config :feed_reader, :options,
        max_items: 1_000,
        max_xml_depth: 128,
        formats: [MyApp.NoticeFormat],
        http_client: MyApp.FeedTransport

  `:formats` adds custom format modules after the built-ins. `:http_client`
  selects a custom transport, which receives its own transport-specific options
  along with the full option list. For Req request options, configure
  `:http_options` instead.

  ## Option defaults

  These defaults apply unless overridden per call or in application config.
  Resource limits bound retained data and parsing work to avoid memory or CPU
  spikes and make resource use more predictable across feeds.
  Collection options without a limit collect all accepted items. Req and custom
  integration options are defined by their respective integrations.

  | Option | Default |
  | --- | --- |
  | `:format` | Automatic detection |
  | `:formats` | `[]` additional formats; RSS, Atom, and RDF are always tried first |
  | `:max_items` | Unset by default (collect all); a positive value stops parsing after that many accepted items |
  | `:item_filter` | Accept all items; per-call only |
  | `:max_detection_bytes` | `65_536` bytes |
  | `:chunk_size` | `65_536` bytes |
  | `:max_xml_events` | `1_000_000` |
  | `:max_xml_depth` | `256` |
  | `:max_attributes_per_element` | `128` |
  | `:max_attribute_bytes` | `65_536` bytes |
  | `:max_feed_metadata_bytes` | `1_048_576` bytes |
  | `:max_item_bytes` | `4_194_304` bytes |
  | `:max_queue_bytes` | `:max_item_bytes` |
  | `:max_parse_passes` | `5` (verified APIs) |
  | `:http_client` | `FeedReader.ReqTransport` (remote APIs) |
  | `:http_options` | `[]`; default transport supplies headers and streaming settings |
  | `:http_retry_attempts` | `5` (remote APIs) |
  | `:retry_delay` | `0` milliseconds (remote APIs) |
  | `:max_compressed_bytes` | `52_428_800` bytes (remote APIs) |
  | `:max_decoded_bytes` | `52_428_800` bytes (remote APIs) |
  | `:max_temp_bytes` | `52_428_800` bytes (remote APIs) |
  | `:max_expansion_ratio` | `100` (remote APIs) |
  | `:feed_url` | `nil` locally; final response URL remotely (per-call only) |
  | `:previous_etag` | `nil` (remote, per-call only) |
  | `:previous_checksum` | `nil` (remote, per-call only) |

  Resource-limit validation, units, and behavior are detailed in the
  `Resource limits` guide. See each function's options section for option-specific
  behavior.
  """

  @typedoc "`:rss`, `:atom`, `:rdf`, `:unknown`, or a custom format's atom ID."
  @type format_id :: atom()

  @option_defaults [
    max_detection_bytes: 65_536,
    chunk_size: 65_536,
    max_xml_events: 1_000_000,
    max_xml_depth: 256,
    max_attributes_per_element: 128,
    max_attribute_bytes: 65_536,
    max_feed_metadata_bytes: 1_048_576,
    max_item_bytes: 4_194_304,
    http_retry_attempts: 5,
    retry_delay: 0,
    max_compressed_bytes: 52_428_800,
    max_decoded_bytes: 52_428_800,
    max_temp_bytes: 52_428_800,
    max_expansion_ratio: 100,
    max_parse_passes: 5
  ]

  @parsing_options_doc """
  - `:format` — format ID or `FeedReader.Format` module; defaults to detection.
  - `:formats` — additional format modules, checked after RSS, Atom, and RDF.
  - `:chunk_size` — positive XML input chunk size; defaults to
    `#{@option_defaults[:chunk_size]}` bytes.
  - `:max_detection_bytes` — positive detection prefix limit; defaults to
    `#{@option_defaults[:max_detection_bytes]}` bytes. Invalid values disable
    detection, so provide a valid explicit `:format` to parse in that case.
  - `:feed_url` — source URL supplied to normalization; defaults to `nil` for
    local sources and the final response URL for remote sources.
  - `:max_xml_events`, `:max_xml_depth`, `:max_attributes_per_element`,
    `:max_attribute_bytes`, `:max_feed_metadata_bytes`, and `:max_item_bytes` —
    non-negative SAX and retained-data limits. Defaults are respectively
    `#{@option_defaults[:max_xml_events]}`, `#{@option_defaults[:max_xml_depth]}`,
    `#{@option_defaults[:max_attributes_per_element]}`,
    `#{@option_defaults[:max_attribute_bytes]}`,
    `#{@option_defaults[:max_feed_metadata_bytes]}`, and
    `#{@option_defaults[:max_item_bytes]}`. Zero is valid; invalid values use
    the defaults.
  - `:max_queue_bytes` — non-negative maximum serialized size of one pending
    event; defaults to `:max_item_bytes`. Zero is valid; invalid values use
    that default.
  - Verified APIs also accept `:max_parse_passes` (default
    `#{@option_defaults[:max_parse_passes]}`), counting validation and delivery.
  """

  @remote_options_doc """
  - `:http_client` — `FeedReader.Transport` implementation; defaults to
    `FeedReader.ReqTransport`.
  - `:http_options` — Req options forwarded to `Req.run/2`. The default transport
    forces raw streaming and disables automatic decompression. `:headers` inside
    this list replaces the default user-agent and accepted-compression headers.
  - `:previous_etag` — binary ETag sent verbatim as `If-None-Match` on GET; a
    304 returns `:not_modified` without downloading a body.
  - `:http_retry_attempts` — non-negative retries after the initial GET;
    defaults to `#{@option_defaults[:http_retry_attempts]}`. The Req transport
    retries status 400 and 500 and most transport errors; TLS and redirect
    failures are terminal. Redirects are limited to five.
  - `:retry_delay` — non-negative milliseconds or an arity-one delay function;
    defaults to `#{@option_defaults[:retry_delay]}`. Invalid values use the
    default.
  - `:previous_checksum` — decoded-body checksum; a match returns
    `:not_changed` and removes the downloaded file.
  - `:max_compressed_bytes`, `:max_decoded_bytes`, and `:max_temp_bytes` —
    non-negative raw-body, decoded-body, and temporary-file byte limits;
    defaults are `#{@option_defaults[:max_compressed_bytes]}` bytes each.
  - `:max_expansion_ratio` — non-negative decoded-to-compressed byte ratio;
    defaults to `#{@option_defaults[:max_expansion_ratio]}`. Invalid limits use
    their defaults. Checksums are computed over decoded bytes.
  """

  @collection_options_doc """
  - `:max_items` — optional positive limit for accepted items. When reached,
    parsing stops and the result's `item_limit_reached?` field is `true`; the
    result may contain only a prefix of the feed. If omitted, all accepted items
    are collected.
  - `:item_filter` — optional one-argument function applied before counting and
    retaining items; invalid values return `{:error, {:invalid_option, :item_filter}}`.
  """

  @streaming_item_limit_doc """
  Streaming APIs do not enforce `:max_items`; it applies only to collection APIs.
  A stream emits items as the consumer enumerates them. Stop enumeration in the
  consumer to limit how many events are processed. Use streaming APIs to process
  large feeds incrementally instead of collecting every item in memory.
  """

  @format_options_doc """
  - `:max_detection_bytes` — positive byte limit for the inspected prefix;
    defaults to `#{@option_defaults[:max_detection_bytes]}`. Invalid values yield
    `:unknown`.
  - `:formats` — custom format modules checked after RSS, Atom, and RDF in list
    order. Duplicates are removed. Modules provide `matches_prefix?/1` and
    `id/0`.
  """

  @doc """
  Detects a format from a bounded binary prefix.

  ## Examples

      xml = ~s(<rss version="2.0"><channel/></rss>)
      FeedReader.detect_format(xml)
      #=> :rss

  See `guides/customization.md` for custom format modules.

  ## Options

  #{@format_options_doc}
  """
  @spec detect_format(binary(), keyword()) :: format_id()
  def detect_format(content, opts \\ []) do
    FeedReader.FormatDetector.detect(content, FeedReader.Options.resolve(opts))
  end

  @doc """
  Checks only the bounded-prefix signature for a format ID or module.

  ## Examples

      xml = ~s(<rss version="2.0"><channel/></rss>)
      FeedReader.validate(xml, :rss)
      #=> true

  See `guides/customization.md` for custom format modules.

  ## Options

  #{@format_options_doc}
  """
  @spec validate(binary(), atom() | module(), keyword()) :: boolean()
  def validate(content, format, opts \\ []) do
    FeedReader.FormatDetector.validate(content, format, FeedReader.Options.resolve(opts))
  end

  @doc """
  Lazily parses a caller-owned local XML file in one SAX pass.

  The returned session emits feed metadata before normalized items. The file is
  never removed by the library, including when enumeration stops early.

  #{String.trim(@streaming_item_limit_doc)}

  ## Examples

      {:ok, session} = FeedReader.stream_file("path/to/feed.xml")
      Enum.each(session.events, &IO.inspect/1)

  ## Options

  #{String.trim(@parsing_options_doc)}
  """
  @spec stream_file(Path.t(), keyword()) :: {:ok, FeedReader.Session.t()} | {:error, term()}
  def stream_file(path, opts \\ []) do
    FeedReader.Parser.stream_file(path, FeedReader.Options.resolve(opts))
  end

  @doc """
  Validates the complete caller-owned local feed before returning an event session.

  The source file is never removed. `:max_parse_passes` bounds validation and
  event delivery passes.

  #{String.trim(@streaming_item_limit_doc)}

  ## Examples

      {:ok, session} = FeedReader.stream_file_verified("path/to/feed.xml")
      Enum.each(session.events, &IO.inspect/1)

  ## Options

  #{String.trim(@parsing_options_doc)}
  """
  @spec stream_file_verified(Path.t(), keyword()) ::
          {:ok, FeedReader.Session.t()} | {:error, term()}
  def stream_file_verified(path, opts \\ []) do
    FeedReader.VerifiedParser.stream_file(path, FeedReader.Options.resolve(opts))
  end

  @doc """
  Downloads and checksums a feed before returning a lazy event session.

  The session emits feed metadata followed by items from one local XML pass.
  Call `close/1` in an `after` block if enumeration may stop early. Matching
  previous checksums or a conditional HTTP 304 return `:not_changed` or
  `:not_modified` without a session.

  #{String.trim(@streaming_item_limit_doc)}

  ## Examples

      url = "https://example.com/feed.xml"
      {:ok, session} = FeedReader.stream(url)

      try do
        session.events
        |> Enum.take(20)
        |> Enum.each(&IO.inspect/1)
      after
        FeedReader.close(session)
      end

  See `guides/streaming.md` for event handling and remote-session cleanup.

  ## Options

  #{String.trim(@remote_options_doc)}

  #{String.trim(@parsing_options_doc)}
  """
  @spec stream(String.t(), keyword()) ::
          {:ok, FeedReader.Session.t() | :not_changed | :not_modified} | {:error, term()}
  def stream(url, opts \\ []) do
    opts = FeedReader.Options.resolve(opts)

    case FeedReader.Downloader.download(url, opts) do
      {:ok, %{path: _path, fetch: _fetch} = download} ->
        create_session(download, opts)

      result ->
        result
    end
  end

  @doc """
  Downloads and validates a feed before exposing its remote event session.

  Matching checksums and conditional HTTP 304 responses return `:not_changed`
  and `:not_modified` without a session. Call `close/1` if enumeration may stop
  early.

  #{String.trim(@streaming_item_limit_doc)}

  ## Examples

      url = "https://example.com/feed.xml"
      {:ok, session} = FeedReader.stream_verified(url)

      try do
        Enum.each(session.events, &IO.inspect/1)
      after
        FeedReader.close(session)
      end

  See `guides/streaming.md` for event handling and remote-session cleanup.

  ## Options

  #{String.trim(@remote_options_doc)}

  #{String.trim(@parsing_options_doc)}
  """
  @spec stream_verified(String.t(), keyword()) ::
          {:ok, FeedReader.Session.t() | :not_changed | :not_modified} | {:error, term()}
  def stream_verified(url, opts \\ []) do
    opts = FeedReader.Options.resolve(opts)

    case FeedReader.Downloader.download(url, opts) do
      {:ok, %{path: path, fetch: fetch} = download} ->
        parser_opts =
          opts
          |> Keyword.put_new(:feed_url, fetch.final_url)
          |> Keyword.put(:owned_source_path, path)

        case FeedReader.VerifiedParser.stream_file(path, parser_opts) do
          {:ok, %FeedReader.Session{} = session} ->
            {:ok, %FeedReader.Session{session | fetch: fetch}}

          {:error, reason} ->
            FeedReader.Downloader.close(download)
            {:error, reason}
        end

      result ->
        result
    end
  end

  defp create_session(%{path: path, fetch: fetch} = download, opts) do
    parser_opts = Keyword.put_new(opts, :feed_url, fetch.final_url)

    case FeedReader.Parser.stream_file(path, parser_opts) do
      {:ok, session} ->
        events =
          Stream.transform(
            session.events,
            fn -> :ok end,
            fn event, state -> {[event], state} end,
            fn _state ->
              FeedReader.Downloader.close(download)
              []
            end
          )

        {:ok, %FeedReader.Session{events: events, fetch: fetch, resource: download}}

      {:error, reason} ->
        FeedReader.Downloader.close(download)
        {:error, reason}
    end
  end

  @doc """
  Closes an owned remote session; safe after completion or repeated calls.

  ## Examples

      {:ok, session} = FeedReader.stream("https://example.com/feed.xml")

      try do
        Enum.take(session.events, 10)
      after
        FeedReader.close(session)
      end

  See `guides/streaming.md` for remote-session ownership and cleanup.
  """
  @spec close(FeedReader.Session.t()) :: :ok
  def close(%FeedReader.Session{resource: %{path: _path} = resource}) do
    FeedReader.Downloader.close(resource)
  end

  def close(%FeedReader.Session{}), do: :ok

  @doc """
  Downloads and collects a feed. `:max_items` may be supplied to stop parsing
  after collecting that many accepted items.

  The default HTTP transport follows redirects automatically, up to five. The
  final response URL is available in `result.fetch.final_url`. Custom transports
  control redirect handling and must report the final URL.

  Memory use is proportional to the number and size of collected items. Without
  `:max_items`, all accepted items are collected. When the limit is reached, the
  result is returned with `item_limit_reached?: true`; the parser stops there,
  so later feed content is not validated. The full remote response is downloaded
  before parsing begins.

  ## Examples

      {:ok, result} =
        FeedReader.fetch_and_parse("https://example.com/feed.xml")

      result.feed.title
      result.fetch.etag

  ## Options

  #{String.trim(@remote_options_doc)}

  #{String.trim(@parsing_options_doc)}

  #{String.trim(@collection_options_doc)}
  """
  @spec fetch_and_parse(String.t(), keyword()) ::
          {:ok, FeedReader.RemoteResult.t() | :not_changed | :not_modified} | {:error, term()}
  def fetch_and_parse(url, opts \\ []) do
    opts = FeedReader.Options.resolve(opts)

    with {:ok, _max_items} <- FeedReader.Collector.max_items(opts),
         {:ok, outcome} <- stream(url, opts) do
      collect_remote_result(outcome, opts)
    end
  end

  defp collect_remote_result(outcome, _opts) when outcome in [:not_changed, :not_modified],
    do: {:ok, outcome}

  defp collect_remote_result(%FeedReader.Session{} = session, opts) do
    with {:ok, result} <- FeedReader.Collector.collect_session(session, opts) do
      {:ok,
       %FeedReader.RemoteResult{
         feed: result.feed,
         items: result.items,
         item_limit_reached?: result.item_limit_reached?,
         fetch: session.fetch
       }}
    end
  end

  @doc """
  Collects a caller-owned local XML file into a parse result.

  If `:max_items` is supplied, parsing stops as soon as that many accepted items
  have been collected. The result's `item_limit_reached?` field is `true`, and
  the rest of the feed is not validated. Without the option, all accepted items
  are collected. The parser stops after the feed's root element, ignoring
  content appended after a complete feed.

  ## Examples

      {:ok, result} = FeedReader.parse_file("path/to/feed.xml")
      Enum.map(result.items, & &1.title)

  ## Options

  #{String.trim(@parsing_options_doc)}

  #{String.trim(@collection_options_doc)}
  """
  @spec parse_file(Path.t(), keyword()) :: {:ok, FeedReader.ParseResult.t()} | {:error, term()}
  def parse_file(path, opts \\ []) do
    FeedReader.Collector.collect(path, FeedReader.Options.resolve(opts))
  end

  @doc """
  Collects XML binary content into a parse result.

  `:max_items` is an optional positive limit; when reached, parsing stops and
  `item_limit_reached?` is set to `true`. Without it, all accepted items are
  collected.

  ## Examples

      xml = File.read!("path/to/feed.xml")
      {:ok, result} = FeedReader.parse_binary(xml)
      result.feed.title

  ## Options

  #{String.trim(@parsing_options_doc)}

  #{String.trim(@collection_options_doc)}
  """
  @spec parse_binary(binary(), keyword()) ::
          {:ok, FeedReader.ParseResult.t()} | {:error, term()}
  def parse_binary(content, opts \\ [])

  def parse_binary(content, opts) when is_binary(content) do
    FeedReader.Collector.parse_stream([content], FeedReader.Options.resolve(opts))
  end

  def parse_binary(_content, _opts), do: {:error, :invalid_binary}

  @doc """
  Collects an enumerable of binary XML chunks into a parse result.

  Chunks are written incrementally to a temporary file and then parsed through
  the same event stream used by `parse_file/2`. The temporary file is removed
  on success and failure. `:max_items` is optional; when reached, parsing stops
  and `item_limit_reached?` is set to `true`. Input chunks are staged before
  parsing begins, so use a streaming API to process large feeds incrementally.

  ## Examples

      chunks = File.stream!("path/to/feed.xml", 16_384, [:raw])
      {:ok, result} = FeedReader.parse_stream(chunks)
      length(result.items)

  ## Options

  #{String.trim(@parsing_options_doc)}

  #{String.trim(@collection_options_doc)}
  """
  @spec parse_stream(Enumerable.t(), keyword()) ::
          {:ok, FeedReader.ParseResult.t()} | {:error, term()}
  def parse_stream(chunks, opts \\ []) do
    FeedReader.Collector.parse_stream(chunks, FeedReader.Options.resolve(opts))
  end
end
