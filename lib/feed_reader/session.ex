defmodule FeedReader.Session do
  @moduledoc """
  A one-pass event stream over a feed.

  Remote sessions own the temporary source used by the event stream and must
  be closed by callers in an `after` block when enumeration is not completed.
  `FeedReader.close/1` is idempotent. Local sessions have no HTTP metadata and
  therefore set `fetch` to `nil`; their caller-owned source is never removed.
  """

  alias FeedReader.Fetch

  @type event ::
          {:feed, FeedReader.Feed.t()}
          | {:item, FeedReader.Item.t()}
          | {:error, term()}

  @type t :: %__MODULE__{
          events: Enumerable.t(),
          fetch: Fetch.t() | nil,
          resource: map() | nil
        }

  defstruct events: nil, fetch: nil, resource: nil
end
