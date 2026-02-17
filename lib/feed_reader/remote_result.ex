defmodule FeedReader.RemoteResult do
  @moduledoc """
  A bounded collection of normalized data and metadata from a remote fetch.

  The result owns no temporary file after collection completes. Its `fetch`
  field contains the HTTP metadata needed by the caller instead.
  """

  alias FeedReader.{Feed, Fetch, Item}

  @type t :: %__MODULE__{
          feed: Feed.t(),
          items: [Item.t()],
          fetch: Fetch.t()
        }

  defstruct feed: nil, items: [], fetch: nil
end
