defmodule FeedReader.Options do
  @moduledoc false

  alias FeedReader.XMLResourceLimits

  @call_only_options [:feed_url, :previous_etag, :previous_checksum, :item_filter]

  @doc "Merges application defaults with call options; malformed application config is ignored."
  @spec resolve(keyword()) :: keyword()
  def resolve(opts) do
    configured = Application.get_env(:feed_reader, :options, [])

    configured =
      if Keyword.keyword?(configured), do: Keyword.drop(configured, @call_only_options), else: []

    Keyword.merge(configured, opts)
  end

  @doc false
  @spec queue_limit(keyword()) :: non_neg_integer()
  def queue_limit(opts) do
    default = XMLResourceLimits.new(opts).max_item_bytes

    case Keyword.get(opts, :max_queue_bytes, default) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> default
    end
  end
end
