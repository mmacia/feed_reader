defmodule FeedReader.Item do
  @moduledoc "A normalized item delivered by a feed parser."

  @type t :: %__MODULE__{
          uuid: String.t() | nil,
          title: String.t() | nil,
          content_full: String.t() | nil,
          content_summary: String.t() | nil,
          language: atom() | nil,
          published_at: DateTime.t() | nil,
          canonical_url: String.t() | nil,
          alternate: map(),
          author: String.t() | nil,
          extensions: %{optional(String.t()) => map()}
        }

  defstruct uuid: nil,
            title: nil,
            content_full: nil,
            content_summary: nil,
            language: nil,
            published_at: nil,
            canonical_url: nil,
            alternate: %{},
            author: nil,
            extensions: %{}
end
