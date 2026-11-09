defmodule FeedReader.AtomCoverageTest do
  use ExUnit.Case, async: true

  alias FeedReader.{Feed, Formats.Atom, Media}

  test "skips unsupported candidates and falls back to metadata when media exceeds the limit" do
    icon = %Media.Candidate{name: {nil, "icon"}, text: "/icon.png"}

    sequence = %Media.CandidateSequence{
      positions: [1, 0],
      values: %{0 => %Media.Candidate{name: {"urn:foreign", "icon"}}, 1 => icon}
    }

    state = %{feed: %{}, feed_candidate_sequence: sequence}

    assert {:ok, %Feed{media: [%Media{url: "/icon.png", role: :icon}]}} =
             Atom.normalize_feed_result(state, [])

    assert %Feed{media: []} = Atom.normalize_feed(state, max_queue_bytes: 0)
  end

  test "stops SAX callbacks after the parser state has an error" do
    handler = Atom.handler()

    state =
      Atom.new_parser_state(fn _event -> flunk("failed parser state emitted an event") end, [])

    assert {:stop, %{error: :prior_error}} =
             handler.handle_event(:end_document, [], %{state | error: :prior_error})
  end
end
