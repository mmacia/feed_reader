defmodule FeedReader.Feed do
  @moduledoc """
  Normalized metadata for a feed.

  Extension metadata is keyed by namespace URI. Format implementations control
  which bounded extension values are retained.
  """

  @type t :: %__MODULE__{
          title: String.t() | nil,
          description: String.t() | nil,
          feed_url: String.t() | nil,
          html_url: String.t() | nil,
          type: :rss | :atom | :rdf,
          categories: [String.t()],
          extensions: %{optional(String.t()) => map()}
        }

  defstruct title: nil,
            description: nil,
            feed_url: nil,
            html_url: nil,
            type: nil,
            categories: [],
            extensions: %{}
end
