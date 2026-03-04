defmodule FeedReader.FormatContractTest do
  use ExUnit.Case, async: true

  alias FeedReader.{Feed, FormatRegistry, Item}
  alias FeedReader.TestSupport.ExternalFormat

  test "built-in registry has a fixed format priority" do
    assert FormatRegistry.builtins() == [
             FeedReader.Formats.RSS,
             FeedReader.Formats.Atom,
             FeedReader.Formats.RDF
           ]
  end

  test "per-call formats append after built-ins without duplicate modules" do
    formats = FormatRegistry.formats([ExternalFormat, FeedReader.Formats.RSS])

    assert formats == FormatRegistry.builtins() ++ [ExternalFormat]
  end

  test "external formats implement detection, parser state, and normalization callbacks" do
    sink = fn event -> send(self(), {:format_event, event}) end
    state = ExternalFormat.new_parser_state(sink, mode: :test)

    assert ExternalFormat.id() == :external_test
    assert ExternalFormat.matches_prefix?("<external-feed>")
    refute ExternalFormat.matches_prefix?("<other-feed>")
    assert ExternalFormat.handler() == FeedReader.TestSupport.ExternalFormatHandler
    assert state.event_sink == sink
    assert state.opts == [mode: :test]

    feed = ExternalFormat.normalize_feed(state, [])
    assert %Feed{title: "External", type: :rss} = feed

    assert ExternalFormat.normalize_item(%{title: "Entry"}, feed, []) ==
             {:ok, %Item{title: "Entry"}}
  end
end
