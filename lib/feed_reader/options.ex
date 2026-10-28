defmodule FeedReader.Options do
  @moduledoc false

  @call_only_options [:feed_url, :previous_etag, :previous_checksum, :item_filter]

  @doc "Merges application defaults with call options; malformed application config is ignored."
  @spec resolve(keyword()) :: keyword()
  def resolve(opts) do
    configured = Application.get_env(:feed_reader, :options, [])

    configured =
      if Keyword.keyword?(configured), do: Keyword.drop(configured, @call_only_options), else: []

    Keyword.merge(configured, opts)
  end
end
