defmodule FeedReader.Media.CandidateTrackerTest do
  use ExUnit.Case, async: true

  alias FeedReader.Media.{CandidateSequence, CandidateTracker}
  alias FeedReader.XML.NamespaceScope

  test "builds candidate paths from the root frame to the current element" do
    feed_scope = NamespaceScope.new() |> NamespaceScope.enter([{"xmlns:a", "urn:atom"}])
    entry_scope = NamespaceScope.enter(feed_scope, [])
    candidate_scope = NamespaceScope.enter(entry_scope, [])

    frames = [
      %{name: "a:entry", namespace_scope: entry_scope},
      %{name: "a:feed", namespace_scope: feed_scope}
    ]

    assert CandidateTracker.path(frames, "a:link", candidate_scope) == [
             {"a:feed", feed_scope},
             {"a:entry", entry_scope},
             {"a:link", candidate_scope}
           ]
  end

  test "tracks feed and item candidates independently and resets item positions" do
    state = %{
      feed_candidate_sequence: CandidateSequence.new(),
      item_candidate_sequence: CandidateSequence.new()
    }

    {state, feed_position} = CandidateTracker.start(state, :feed)
    {state, first_item_position} = CandidateTracker.start(state, :item)
    {state, second_item_position} = CandidateTracker.start(state, :item)

    state = CandidateTracker.complete(state, second_item_position, :second_item)
    state = CandidateTracker.complete(state, feed_position, :feed_candidate)
    state = CandidateTracker.complete(state, first_item_position, :first_item)

    assert CandidateSequence.finalize(state.feed_candidate_sequence) == [:feed_candidate]

    assert CandidateSequence.finalize(state.item_candidate_sequence) == [
             :first_item,
             :second_item
           ]

    state = CandidateTracker.reset_item(state)
    assert CandidateSequence.finalize(state.item_candidate_sequence) == []
    assert CandidateSequence.finalize(state.feed_candidate_sequence) == [:feed_candidate]
    assert {_, {:item, 0}} = CandidateTracker.start(state, :item)
  end

  test "expands candidate attribute names in their namespace scope" do
    namespace_scope =
      NamespaceScope.new()
      |> NamespaceScope.enter([{"xmlns:media", "urn:media"}])

    assert CandidateTracker.expanded_attributes(
             [{"href", "image.jpg"}, {"media:width", "320"}],
             namespace_scope
           ) == %{{nil, "href"} => "image.jpg", {"urn:media", "width"} => "320"}
  end
end
