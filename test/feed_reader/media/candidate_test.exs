defmodule FeedReader.Media.CandidateTest do
  use ExUnit.Case, async: true

  alias FeedReader.Media
  alias FeedReader.XML.{ChildAccumulator, Name, NamespaceScope}

  @media_rss "http://search.yahoo.com/mrss/"

  test "finalizes nested candidates in start order after the child closes first" do
    sequence = Media.CandidateSequence.new()
    {sequence, content_position} = Media.CandidateSequence.start(sequence)
    {sequence, thumbnail_position} = Media.CandidateSequence.start(sequence)

    thumbnail =
      Media.Candidate.finalize(
        {"urn:media", "thumbnail"},
        %{{nil, "url"} => "thumbnail.jpg"},
        ChildAccumulator.new(),
        ""
      )

    content =
      Media.Candidate.finalize(
        {"urn:media", "content"},
        %{{nil, "url"} => "content.jpg"},
        ChildAccumulator.new(),
        ""
      )

    sequence = Media.CandidateSequence.complete(sequence, thumbnail_position, thumbnail)
    sequence = Media.CandidateSequence.complete(sequence, content_position, content)

    assert Media.CandidateSequence.finalize(sequence) == [content, thumbnail]
  end

  test "keeps expanded child names distinct and separate from attributes" do
    children =
      ChildAccumulator.new()
      |> ChildAccumulator.add({nil, "url"}, "child-url.jpg")
      |> ChildAccumulator.add({"urn:media", "title"}, "Media title")
      |> ChildAccumulator.add({"urn:extension", "title"}, "Extension title")

    candidate =
      Media.Candidate.finalize(
        {"urn:media", "content"},
        %{{nil, "url"} => "attribute-url.jpg"},
        children,
        ""
      )

    assert candidate.name == {"urn:media", "content"}
    assert candidate.attributes == %{{nil, "url"} => "attribute-url.jpg"}

    assert candidate.children == %{
             {nil, "url"} => "child-url.jpg",
             {"urn:media", "title"} => "Media title",
             {"urn:extension", "title"} => "Extension title"
           }
  end

  test "captures only a direct Media RSS title after namespace rebinding" do
    media_scope = NamespaceScope.new() |> NamespaceScope.enter([{"xmlns:m", @media_rss}])

    foreign_scope =
      NamespaceScope.enter(media_scope, [{"xmlns:m", "urn:foreign"}])

    media_title_name = Name.element("m:title", media_scope)
    foreign_title_name = Name.element("m:title", foreign_scope)

    children =
      ChildAccumulator.new()
      |> ChildAccumulator.add(media_title_name, %{"_text" => "  Media title  "})
      |> ChildAccumulator.add(foreign_title_name, "Rebound title")

    candidate =
      Media.Candidate.finalize(
        Name.element("m:content", media_scope),
        %{{nil, "url"} => "content.jpg"},
        children,
        ""
      )

    assert candidate.title == "Media title"
    assert candidate.children[media_title_name] == %{"_text" => "  Media title  "}
    assert candidate.children[{"urn:foreign", "title"}] == "Rebound title"
  end

  test "keeps content and nested thumbnail titles independent" do
    group = candidate_with_title({@media_rss, "group"}, "Group title")
    thumbnail = candidate_with_title({@media_rss, "thumbnail"}, "Thumbnail title")

    content_children =
      ChildAccumulator.new()
      |> ChildAccumulator.add({@media_rss, "title"}, "Content title")
      |> ChildAccumulator.add({@media_rss, "thumbnail"}, thumbnail)

    content =
      Media.Candidate.finalize(
        {@media_rss, "content"},
        %{{nil, "url"} => "content.jpg"},
        content_children,
        ""
      )

    assert group.title == nil
    assert content.title == "Content title"
    assert thumbnail.title == "Thumbnail title"
  end

  test "skips blank and non-text titles and selects the first usable repeated title" do
    children =
      ChildAccumulator.new()
      |> ChildAccumulator.add({@media_rss, "title"}, " \n ")
      |> ChildAccumulator.add({@media_rss, "title"}, %{"_text" => :not_text})
      |> ChildAccumulator.add({@media_rss, "title"}, %{"markup" => "not text"})
      |> ChildAccumulator.add({@media_rss, "title"}, "  Article title  ")
      |> ChildAccumulator.add({@media_rss, "title"}, "Later title")

    candidate =
      Media.Candidate.finalize(
        {@media_rss, "content"},
        %{},
        children,
        ""
      )

    assert candidate.title == "Article title"
  end

  test "leaves title nil when a content candidate has no direct title child" do
    candidate =
      Media.Candidate.finalize(
        {@media_rss, "content"},
        %{},
        ChildAccumulator.new(),
        ""
      )

    assert candidate.title == nil
  end

  defp candidate_with_title(name, title) do
    children = ChildAccumulator.add(ChildAccumulator.new(), {@media_rss, "title"}, title)
    Media.Candidate.finalize(name, %{}, children, "")
  end
end
