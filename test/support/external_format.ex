defmodule FeedReader.TestSupport.ExternalFormat do
  @moduledoc false
  @behaviour FeedReader.Format

  alias FeedReader.{Feed, Item}

  @impl true
  def id, do: :external_test

  @impl true
  def matches_prefix?("<external-feed" <> _rest), do: true
  def matches_prefix?(_prefix), do: false

  @impl true
  def handler, do: FeedReader.TestSupport.ExternalFormatHandler

  @impl true
  def new_parser_state(event_sink, opts), do: %{event_sink: event_sink, opts: opts}

  @impl true
  def normalize_feed(_state, _opts), do: %Feed{title: "External", type: :rss}

  @impl true
  def normalize_item(%{title: title}, _feed, _opts), do: {:ok, %Item{title: title}}
end
