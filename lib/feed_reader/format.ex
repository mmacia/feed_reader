defmodule FeedReader.Format do
  @moduledoc """
  Behaviour implemented by built-in and explicitly supplied feed formats.

  Detection examines only the bounded, replayable prefix provided by the caller.
  XML formats provide their dedicated Saxy handler and create parser state with
  an event sink; normalization returns the standalone feed and item value types.
  """

  @callback id() :: atom()
  @callback detect(prefix :: binary()) :: :match | :no_match
  @callback handler() :: module()
  @callback new_parser_state(event_sink :: function(), opts :: keyword()) :: term()

  @callback normalize_feed(state :: term(), opts :: keyword()) :: FeedReader.Feed.t()

  @callback normalize_item(
              raw_item :: map(),
              feed :: FeedReader.Feed.t(),
              opts :: keyword()
            ) :: {:ok, FeedReader.Item.t()} | :skip | {:error, term()}
end
