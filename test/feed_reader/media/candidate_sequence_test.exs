defmodule FeedReader.Media.CandidateSequenceTest do
  use ExUnit.Case, async: true

  alias FeedReader.Media

  test "finalizes candidates in start order when nested candidates close first" do
    sequence = Media.CandidateSequence.new()
    {sequence, content} = Media.CandidateSequence.start(sequence)
    {sequence, thumbnail} = Media.CandidateSequence.start(sequence)

    sequence = Media.CandidateSequence.complete(sequence, thumbnail, :thumbnail)
    sequence = Media.CandidateSequence.complete(sequence, content, :content)

    assert Media.CandidateSequence.finalize(sequence) == [:content, :thumbnail]
  end

  test "accumulates repeated candidates linearly and preserves encounter order" do
    {sequence, positions} =
      Enum.reduce(1..1_000, {Media.CandidateSequence.new(), []}, fn value,
                                                                    {sequence, positions} ->
        {sequence, position} = Media.CandidateSequence.start(sequence)
        sequence = Media.CandidateSequence.complete(sequence, position, value)
        {sequence, [position | positions]}
      end)

    assert Media.CandidateSequence.finalize(sequence) == Enum.to_list(1..1_000)
    assert Enum.reverse(positions) == Enum.to_list(0..999)
  end
end
