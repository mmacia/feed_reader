defmodule FeedReader.Feed do
  @moduledoc """
  Normalized metadata for a feed.

  `media` contains the feed's normalized media resources and defaults to an
  empty list until media extraction is provided by a format.

  Extension metadata is keyed by namespace URI. Format implementations control
  which bounded extension values are retained.
  """

  alias FeedReader.Media

  @type t :: %__MODULE__{
          title: String.t() | nil,
          description: String.t() | nil,
          feed_url: String.t() | nil,
          html_url: String.t() | nil,
          type: :rss | :atom | :rdf,
          categories: [String.t()],
          media: [Media.t()],
          extensions: %{optional(String.t()) => map()}
        }

  defstruct title: nil,
            description: nil,
            feed_url: nil,
            html_url: nil,
            type: nil,
            categories: [],
            media: [],
            extensions: %{}
end
