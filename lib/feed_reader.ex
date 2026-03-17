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
end
