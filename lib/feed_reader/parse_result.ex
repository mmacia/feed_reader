defmodule FeedReader.ParseResult do
  @moduledoc "A bounded collection of normalized data from a local source."

  alias FeedReader.{Feed, Item}

  @type t :: %__MODULE__{
          feed: Feed.t(),
          items: [Item.t()]
        }

  defstruct feed: nil, items: []
end
