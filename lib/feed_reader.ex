defmodule FeedReader do
  @moduledoc """
  Standalone feed fetching and parsing library.

  This module exposes the public format detection and validation helpers.
  """

  @typedoc "`:rss`, `:atom`, `:rdf`, `:unknown`, or a custom format's atom ID."
  @type format_id :: atom()

  @doc """
  Detects a format from a bounded binary prefix.

  ## Options
  - `:max_detection_bytes` — `pos_integer()`; default `65_536`; invalid values yield `:unknown`.
  - `:formats` — list of modules, checked after RSS, Atom, and RDF in list order; duplicates removed.
    Custom modules provide `matches_prefix?/1` and `id/0`.
  """
  @spec detect_format(binary(), keyword()) :: format_id()
  def detect_format(content, opts \\ []) do
    FeedReader.FormatDetector.detect(content, opts)
  end

  @doc """
  Checks only the bounded-prefix signature for a format ID or module.

  ## Options
  - `:max_detection_bytes` — `pos_integer()`, default `65_536`; invalid values yield `false`.
  - `:formats` — custom modules used to resolve custom format IDs. Modules provide
    `matches_prefix?/1` and `id/0`; passing the format module directly also works.
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
  - `:chunk_size` — positive integer number of bytes supplied to the XML parser
    per chunk. Defaults to `65_536`.
  - `:max_detection_bytes` — positive integer limit for the prefix inspected
    during format detection. Defaults to `65_536`. Invalid values produce
    `{:error, :unknown}` unless a valid explicit `:format` is supplied.
  - `:feed_url` — optional source URL passed to format normalizers and stored in
    the normalized feed metadata. Defaults to `nil`.
  - `:max_xml_events` — non-negative integer maximum SAX events. Defaults to
    `1_000_000`.
  - `:max_xml_depth` — non-negative integer maximum XML nesting depth. Defaults
    to `256`.
  - `:max_attributes_per_element` — non-negative integer maximum attributes on
    one element. Defaults to `128`.
  - `:max_attribute_bytes` — non-negative integer maximum bytes used by one
    element's attributes. Defaults to `65_536`.
  - `:max_feed_metadata_bytes` — non-negative integer maximum retained feed
    metadata bytes. Defaults to `1_048_576`.
  - `:max_item_bytes` — non-negative integer maximum retained bytes for one
    item. Defaults to `4_194_304`.

  Zero is valid for resource limits. Missing or invalid resource-limit values
  use their defaults. Additional options are passed through to the selected
  format implementation.
  """
  @spec stream_file(Path.t(), keyword()) :: {:ok, FeedReader.Session.t()} | {:error, term()}
  def stream_file(path, opts \\ []) do
    FeedReader.Parser.stream_file(path, opts)
  end
end
