defmodule FeedReader.Media.CandidatePathTest do
  use ExUnit.Case, async: true

  alias FeedReader.Media
  alias FeedReader.XML.NamespaceScope

  @rss "http://purl.org/rss/1.0/"
  @atom "http://www.w3.org/2005/Atom"
  @rdf "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
  @media_rss "http://search.yahoo.com/mrss/"

  test "accepts only direct RSS channel images and item enclosures" do
    assert eligible?(:rss, [{"rss", []}, {"channel", []}, {"image", []}])

    assert eligible?(:rss, [
             {"rss", []},
             {"channel", []},
             {"item", []},
             {"enclosure", []}
           ])

    refute eligible?(:rss, [{"rss", []}, {"wrapper", []}, {"channel", []}, {"image", []}])

    refute eligible?(:rss, [
             {"rss", []},
             {"channel", []},
             {"x:item", [{"xmlns:x", "urn:foreign"}]},
             {"enclosure", []}
           ])
  end

  test "accepts direct Atom feed icons and entry links/content across aliases" do
    for local_name <- ["icon", "logo"] do
      assert eligible?(:atom, [
               {"a:feed", [{"xmlns:a", @atom}]},
               {"a:#{local_name}", []}
             ])
    end

    for local_name <- ["link", "content"] do
      assert eligible?(:atom, [
               {"a:feed", [{"xmlns:a", @atom}]},
               {"a:entry", []},
               {"a:#{local_name}", []}
             ])
    end

    refute eligible?(:atom, [
             {"feed", [{"xmlns", @atom}]},
             {"wrapper", []},
             {"icon", []}
           ])

    refute eligible?(:atom, [
             {"a:feed", [{"xmlns:a", @atom}]},
             {"x:entry", [{"xmlns:x", "urn:foreign"}]},
             {"a:content", []}
           ])
  end

  test "accepts RDF channel images with scoped core names and legacy roots" do
    assert eligible?(:rdf, [
             {"r:RDF", [{"xmlns:r", @rdf}, {"xmlns:s", @rss}]},
             {"s:channel", []},
             {"s:image", []}
           ])

    assert eligible?(:rdf, [
             {"rdf:RDF", []},
             {"channel", []},
             {"image", []}
           ])

    refute eligible?(:rdf, [
             {"r:RDF", [{"xmlns:r", @rdf}]},
             {"x:channel", [{"xmlns:x", "urn:foreign"}]},
             {"image", []}
           ])

    refute eligible?(:rdf, [
             {"r:RDF", [{"xmlns:r", @rdf}, {"xmlns:s", @rss}]},
             {"wrapper", []},
             {"s:channel", []},
             {"s:image", []}
           ])
  end

  test "rejects unrelated formats and candidate paths" do
    refute Media.CandidatePath.eligible?(:rss, [{"rss", []}, {"channel", []}])
    refute Media.CandidatePath.eligible?(:unknown, [{"rss", []}, {"channel", []}, {"image", []}])
  end

  test "accepts direct and grouped Media RSS content and thumbnail paths for each item format" do
    suffixes = [
      [{"m:content", []}],
      [{"m:thumbnail", []}],
      [{"m:group", []}, {"m:content", []}],
      [{"m:group", []}, {"m:thumbnail", []}],
      [{"m:content", []}, {"m:thumbnail", []}],
      [{"m:group", []}, {"m:content", []}, {"m:thumbnail", []}]
    ]

    for format <- [:rss, :atom, :rdf], suffix <- suffixes do
      assert eligible?(format, item_path(format) ++ suffix),
             "expected #{inspect(suffix)} to be eligible for #{format}"
    end
  end

  test "rejects Media RSS candidates outside direct owners and supported parent paths" do
    refute eligible?(:rss, [
             {"rss", [{"xmlns:m", @media_rss}]},
             {"channel", []},
             {"item", []},
             {"wrapper", []},
             {"m:content", []}
           ])

    refute eligible?(:atom, [
             {"feed", [{"xmlns", @atom}, {"xmlns:m", @media_rss}]},
             {"entry", []},
             {"m:group", []},
             {"wrapper", []},
             {"m:thumbnail", []}
           ])

    refute eligible?(:rdf, [
             {"rdf:RDF", [{"xmlns:rdf", @rdf}, {"xmlns:m", @media_rss}]},
             {"item", []},
             {"m:group", []},
             {"m:group", []},
             {"m:content", []}
           ])
  end

  test "matches each Media RSS element in its own scope across aliases and rebindings" do
    path = [
      {"rss", [{"xmlns:m", "urn:foreign"}]},
      {"channel", []},
      {"item", []},
      {"m:group", [{"xmlns:m", @media_rss}]},
      {"n:content", [{"xmlns:m", "urn:foreign"}, {"xmlns:n", @media_rss}]}
    ]

    assert eligible?(:rss, path)

    refute eligible?(:rss, path ++ [{"n:thumbnail", [{"xmlns:n", "urn:foreign"}]}])

    refute eligible?(:rss, [
             {"rss", [{"xmlns:m", @media_rss}]},
             {"channel", []},
             {"item", []},
             {"m:group", []},
             {"m:content", [{"xmlns:m", "urn:foreign"}]}
           ])
  end

  test "supports default namespace Media RSS element names" do
    assert eligible?(:atom, [
             {"feed", [{"xmlns", @atom}]},
             {"entry", []},
             {"group", [{"xmlns", @media_rss}]},
             {"content", []},
             {"thumbnail", []}
           ])
  end

  defp eligible?(format, elements), do: Media.CandidatePath.eligible?(format, path(elements))

  defp item_path(:rss),
    do: [{"rss", [{"xmlns:m", @media_rss}]}, {"channel", []}, {"item", []}]

  defp item_path(:atom),
    do: [{"feed", [{"xmlns", @atom}, {"xmlns:m", @media_rss}]}, {"entry", []}]

  defp item_path(:rdf),
    do: [{"rdf:RDF", [{"xmlns:rdf", @rdf}, {"xmlns:m", @media_rss}]}, {"item", []}]

  defp path(elements) do
    {segments, _scope} =
      Enum.map_reduce(elements, NamespaceScope.new(), fn {name, attributes}, scope ->
        scope = NamespaceScope.enter(scope, attributes)
        {{name, scope}, scope}
      end)

    segments
  end
end
