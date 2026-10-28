defmodule FeedReader.RemoteResult do
  @moduledoc """
  A collection of normalized data and metadata from a remote fetch.

  The result owns no temporary file after collection completes. Its `fetch`
  field contains the HTTP metadata needed by the caller instead. The
  `item_limit_reached?` field indicates whether collection stopped at the
  configured item limit.
  """

  alias FeedReader.{Feed, Fetch, Item}

  @type t :: %__MODULE__{
          feed: Feed.t(),
          items: [Item.t()],
          fetch: Fetch.t(),
          item_limit_reached?: boolean()
        }

  defstruct feed: nil, items: [], fetch: nil, item_limit_reached?: false
end
