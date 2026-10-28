defmodule FeedReader.ParseResult do
  @moduledoc """
  A collection of normalized data from a local source.

  `item_limit_reached?` is `true` when parsing stopped at the configured item
  cap; the collected items may then be only a prefix of the feed.
  """

  alias FeedReader.{Feed, Item}

  @type t :: %__MODULE__{
          feed: Feed.t(),
          items: [Item.t()],
          item_limit_reached?: boolean()
        }

  defstruct feed: nil, items: [], item_limit_reached?: false
end
