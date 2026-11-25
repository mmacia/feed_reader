defmodule FeedReader.Session do
  @moduledoc """
  An event stream over a feed, backed by a local or library-owned XML file.

  Local sessions, created by `FeedReader.stream_file/2` and
  `FeedReader.stream_file_verified/2`, read the caller's file and are
  re-enumerable. That file is never removed.

  Default remote sessions are one-pass. Fully consuming the events removes the
  library-owned temporary file; call `FeedReader.close/1` in an `after` block
  when enumeration may stop early. Replayable remote sessions
  (`:replayable: true`) retain the owned file after every parsing pass, so
  `events` can be enumerated again from the beginning. Their file is removed
  only by `FeedReader.close/1`, which is idempotent.

  Remote sessions include HTTP metadata in `fetch`; local sessions set `fetch`
  to `nil`.
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
