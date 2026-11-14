defmodule FeedReader.MediaCandidateSequenceTest do
  use ExUnit.Case, async: true

  alias FeedReader.MediaCandidateSequence

  test "finalizes candidates in start order when nested candidates close first" do
    sequence = MediaCandidateSequence.new()
    {sequence, content} = MediaCandidateSequence.start(sequence)
    {sequence, thumbnail} = MediaCandidateSequence.start(sequence)

    sequence = MediaCandidateSequence.complete(sequence, thumbnail, :thumbnail)
    sequence = MediaCandidateSequence.complete(sequence, content, :content)

    assert MediaCandidateSequence.finalize(sequence) == [:content, :thumbnail]
  end

  test "accumulates repeated candidates linearly and preserves encounter order" do
    {sequence, positions} =
      Enum.reduce(1..1_000, {MediaCandidateSequence.new(), []}, fn value, {sequence, positions} ->
        {sequence, position} = MediaCandidateSequence.start(sequence)
        sequence = MediaCandidateSequence.complete(sequence, position, value)
        {sequence, [position | positions]}
      end)

    assert MediaCandidateSequence.finalize(sequence) == Enum.to_list(1..1_000)
    assert Enum.reverse(positions) == Enum.to_list(0..999)
  end
end
