defmodule FeedReader.TestSupport.ParserHaltFormat do
  @moduledoc false

  @behaviour FeedReader.Format

  @impl true
  def id, do: :parser_halt

  @impl true
  def matches_prefix?(_prefix), do: true

  @impl true
  def handler, do: FeedReader.TestSupport.ParserHaltHandler

  @impl true
  def new_parser_state(_event_sink, opts) do
    if Keyword.get(opts, :normal_exit), do: exit(:normal)
    if Keyword.get(opts, :abnormal_exit), do: exit(:parser_crashed)
    nil
  end

  @impl true
  def normalize_feed(_state, _opts), do: %FeedReader.Feed{}

  @impl true
  def normalize_item(_raw_item, _feed, _opts), do: :skip
end
