defmodule FeedReader.Format do
  @moduledoc """
  Behaviour implemented by built-in and explicitly supplied feed formats.

  Detection examines only the bounded, replayable prefix provided by the caller.
  XML formats provide their dedicated Saxy handler and create parser state with
  an event sink; normalization returns the standalone feed and item value types.

  Callback options are keyword lists. The shared parser limits are:

  - `:max_xml_events` — non-negative integer; default `1_000_000`.
  - `:max_xml_depth` — non-negative integer; default `256`.
  - `:max_attributes_per_element` — non-negative integer; default `128`.
  - `:max_attribute_bytes` — non-negative integer; default `65_536`.
  - `:max_feed_metadata_bytes` — non-negative integer; default `1_048_576`.
  - `:max_item_bytes` — non-negative integer; default `4_194_304`.

  Zero is a valid limit. Missing or invalid limit values use the defaults. A
  format may define additional options; their meaning and accepted values are
  documented by that format. Parser limits are consumed while building parser
  state; the keyword list is also passed to the normalization callbacks. RSS
  recognizes `:feed_url` as an optional URL string.
  """

  @typedoc "Keyword options accepted by format callbacks."
  @type options :: keyword()

  @doc "Returns the stable atom identifying this format; no options are accepted."
  @callback id() :: atom()

  @doc """
  Tests a bounded prefix for this format.

  The prefix is at most `:max_detection_bytes` bytes. That option belongs to the
  caller of format detection, not this callback; it must be a positive integer
  and defaults to `65_536`. This callback accepts no options and must not read
  beyond the supplied prefix.
  """
  @callback matches_prefix?(prefix :: binary()) :: boolean()

  @doc "Returns the module implementing `Saxy.Handler`; no options are accepted."
  @callback handler() :: module()

  @doc """
  Creates the initial state for `handler/0` and its event sink.

  The arity-one `event_sink` receives `{:feed, feed}` and `{:item, item}` events
  as values are normalized. `opts` accepts the shared parser limits documented
  in this module's options section, plus options defined by the format. RSS
  accepts `:feed_url` as an optional `String.t()` and forwards it to
  `normalize_feed/2`.
  """
  @callback new_parser_state(event_sink :: (term() -> term()), opts :: options()) :: term()

  @doc """
  Converts completed format-specific parser state into normalized feed metadata.

  `opts` accepts the shared parser limits documented in this module's options
  section and format-specific options. RSS recognizes `:feed_url` as an optional
  `String.t()`; when omitted, the resulting feed URL is `nil`.
  """
  @callback normalize_feed(state :: term(), opts :: options()) :: FeedReader.Feed.t()

  @doc """
  Converts one raw format-specific item using normalized feed metadata.

  Return `{:ok, item}` to deliver an item, `:skip` to omit it, or
  `{:error, reason}` to terminate parsing. `opts` is a keyword list containing
  the shared parser limits and any format-specific options. The RSS implementation
  currently uses no item-normalization options.
  """
  @callback normalize_item(
              raw_item :: map(),
              feed :: FeedReader.Feed.t(),
              opts :: options()
            ) :: {:ok, FeedReader.Item.t()} | :skip | {:error, term()}
end
