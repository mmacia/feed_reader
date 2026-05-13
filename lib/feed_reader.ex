defmodule FeedReader do
  @moduledoc """
  Standalone feed fetching and parsing library.

  This module exposes format detection, validation, local parsing, and streaming
  helpers.
  """

  @typedoc "`:rss`, `:atom`, `:rdf`, `:unknown`, or a custom format's atom ID."
  @type format_id :: atom()

  @doc """
  Detects a format from a bounded binary prefix.

  ## Options
  - `:max_detection_bytes` — positive byte limit for the inspected prefix;
    defaults to `65_536`. Invalid values yield `:unknown`.
  - `:formats` — custom format modules checked after RSS, Atom, and RDF in list
    order. Duplicates are removed. Modules provide `matches_prefix?/1` and
    `id/0`.
  """
  @spec detect_format(binary(), keyword()) :: format_id()
  def detect_format(content, opts \\ []) do
    FeedReader.FormatDetector.detect(content, opts)
  end

  @doc """
  Checks only the bounded-prefix signature for a format ID or module.

  ## Options
  - `:max_detection_bytes` — positive byte limit for the inspected prefix;
    defaults to `65_536`. Invalid values yield `false`.
  - `:formats` — custom format modules used to resolve custom format IDs.
    Modules provide `matches_prefix?/1` and `id/0`; passing the format module
    directly also works.
  """
  @spec validate(binary(), atom() | module(), keyword()) :: boolean()
  def validate(content, format, opts \\ []) do
    FeedReader.FormatDetector.validate(content, format, opts)
  end

  @doc """
  Lazily parses a caller-owned local XML file in one SAX pass.

  The returned session emits feed metadata before normalized items. The file is
  never removed by the library, including when enumeration stops early.

  ## Options

  - `:format` — an atom format ID (`:rss`, `:atom`, or `:rdf`) or a format
    module. When omitted, the format is detected from the file prefix.
  - `:formats` — a list of additional format modules. They are checked after
    the built-in RSS, Atom, and RDF formats and may be selected with `:format`.
    Custom modules must implement `FeedReader.Format`.
  - `:chunk_size` — positive number of bytes supplied to the XML parser per
    chunk. Defaults to `65_536`.
  - `:max_detection_bytes` — positive byte limit for format detection. Defaults
    to `65_536`. Invalid values produce `{:error, :unknown}` unless a valid
    explicit `:format` is supplied.
  - `:feed_url` — optional source URL passed to format normalizers and stored in
    the normalized feed metadata. Defaults to `nil`.
  - `:formats` — additional format modules checked after the built-in formats.
  - `:max_xml_events` — non-negative maximum SAX events. Defaults to
    `1_000_000`.
  - `:max_xml_depth` — non-negative maximum XML nesting depth. Defaults to
    `256`.
  - `:max_attributes_per_element` — non-negative maximum attributes on one
    element. Defaults to `128`.
  - `:max_attribute_bytes` — non-negative maximum bytes used by one element's
    attributes. Defaults to `65_536`.
  - `:max_feed_metadata_bytes` — non-negative maximum retained feed metadata
    bytes. Defaults to `1_048_576`.
  - `:max_item_bytes` — non-negative maximum retained bytes for one item.
    Defaults to `4_194_304`.
  - `:max_queue_bytes` — non-negative maximum serialized size of one pending
    event. Defaults to `:max_item_bytes`.

  Zero is valid for resource limits. Missing or invalid resource-limit values
  use their defaults. Additional options are passed through to the selected
  format implementation.
  """
  @spec stream_file(Path.t(), keyword()) :: {:ok, FeedReader.Session.t()} | {:error, term()}
  def stream_file(path, opts \\ []) do
    FeedReader.Parser.stream_file(path, opts)
  end

  @doc """
  Collects a caller-owned local XML file into a bounded parse result.

  `:max_items` is required and must be a positive integer. The parser continues
  through the end of the source so malformed tails are reported; an item
  accepted beyond the limit returns `{:error, {:max_items_exceeded, max_items}}`.
  `:item_filter`, when supplied, must be a one-argument function and is applied
  before counting and collecting items.

  ## Options

  Accepts all `stream_file/2` parsing options, plus:

  - `:max_items` — required positive integer limit for accepted items. The
    collector continues parsing after reaching the limit and returns
    `{:error, {:max_items_exceeded, max_items}}` if another item is accepted.
  - `:item_filter` — optional one-argument function applied before counting and
    retaining an item.
  """
  @spec parse_file(Path.t(), keyword()) :: {:ok, FeedReader.ParseResult.t()} | {:error, term()}
  def parse_file(path, opts \\ []) do
    FeedReader.Collector.collect(path, opts)
  end

  @doc """
  Collects XML binary content into a bounded parse result.

  ## Options

  Accepts the same parsing and collection options as `parse_file/2`, including
  required `:max_items` and optional `:item_filter`.
  """
  @spec parse_binary(binary(), keyword()) ::
          {:ok, FeedReader.ParseResult.t()} | {:error, term()}
  def parse_binary(content, opts \\ [])

  def parse_binary(content, opts) when is_binary(content) do
    FeedReader.Collector.parse_stream([content], opts)
  end

  def parse_binary(_content, _opts), do: {:error, :invalid_binary}

  @doc """
  Collects an enumerable of binary XML chunks into a bounded parse result.

  Chunks are written incrementally to a temporary file and then parsed through
  the same event stream used by `parse_file/2`. The temporary file is removed
  on success and failure.

  ## Options

  Accepts the same parsing and collection options as `parse_file/2`, including
  required `:max_items` and optional `:item_filter`.
  """
  @spec parse_stream(Enumerable.t(), keyword()) ::
          {:ok, FeedReader.ParseResult.t()} | {:error, term()}
  def parse_stream(chunks, opts \\ []) do
    FeedReader.Collector.parse_stream(chunks, opts)
  end
end
