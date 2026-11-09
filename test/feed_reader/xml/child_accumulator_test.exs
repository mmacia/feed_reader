defmodule FeedReader.XML.ChildAccumulatorTest do
  use ExUnit.Case, async: true

  alias FeedReader.XML.ChildAccumulator

  test "keeps a single child as a scalar" do
    child = %{"_text" => "value"}

    result =
      ChildAccumulator.new()
      |> ChildAccumulator.add("title", child)
      |> ChildAccumulator.finalize()

    assert result == %{"title" => child}
  end

  test "keeps repeated children as an ordered list while other children stay scalar" do
    result =
      ChildAccumulator.new()
      |> ChildAccumulator.add("title", "first")
      |> ChildAccumulator.add("category", "news")
      |> ChildAccumulator.add("title", "second")
      |> ChildAccumulator.add("title", "third")
      |> ChildAccumulator.finalize()

    assert result == %{"title" => ["first", "second", "third"], "category" => "news"}
  end

  test "treats list-valued children as values when accumulating repeats" do
    result =
      ChildAccumulator.new()
      |> ChildAccumulator.add("content", ["first", "part"])
      |> ChildAccumulator.add("content", ["second", "part"])
      |> ChildAccumulator.finalize()

    assert result == %{"content" => [["first", "part"], ["second", "part"]]}
  end
end
