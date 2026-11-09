defmodule FeedReader.XML.NameTest do
  use ExUnit.Case, async: true

  alias FeedReader.XML.{Name, NamespaceScope}

  test "resolves element names through prefixed and default namespaces" do
    prefixed = NamespaceScope.new() |> NamespaceScope.enter([{"xmlns:a", "urn:atom"}])
    default = NamespaceScope.new() |> NamespaceScope.enter([{"xmlns", "urn:atom"}])

    assert Name.element("a:feed", prefixed) == {"urn:atom", "feed"}
    assert Name.element("feed", default) == {"urn:atom", "feed"}
    assert Name.element("feed", NamespaceScope.new()) == {nil, "feed"}
  end

  test "resolves attributes without applying the default namespace" do
    scope =
      NamespaceScope.new()
      |> NamespaceScope.enter([{"xmlns", "urn:default"}, {"xmlns:r", "urn:rdf"}])

    assert Name.attribute("resource", scope) == {nil, "resource"}
    assert Name.attribute("r:resource", scope) == {"urn:rdf", "resource"}
    assert Name.attribute("xml:lang", scope) == {"http://www.w3.org/XML/1998/namespace", "lang"}
    assert Name.attribute("xmlns", scope) == {"http://www.w3.org/2000/xmlns/", "xmlns"}
    assert Name.attribute("xmlns:r", scope) == {"http://www.w3.org/2000/xmlns/", "r"}
  end

  test "matches core namespaces, namespace-less feeds, and the legacy RDF root" do
    atom =
      NamespaceScope.new() |> NamespaceScope.enter([{"xmlns:a", "http://www.w3.org/2005/Atom"}])

    atom_default =
      NamespaceScope.new() |> NamespaceScope.enter([{"xmlns", "http://www.w3.org/2005/Atom"}])

    rss = NamespaceScope.new() |> NamespaceScope.enter([{"xmlns", "http://purl.org/rss/1.0/"}])

    rdf =
      NamespaceScope.new()
      |> NamespaceScope.enter([{"xmlns:r", "http://www.w3.org/1999/02/22-rdf-syntax-ns#"}])

    rdf_default =
      NamespaceScope.new()
      |> NamespaceScope.enter([{"xmlns", "http://www.w3.org/1999/02/22-rdf-syntax-ns#"}])

    wrong = NamespaceScope.new() |> NamespaceScope.enter([{"xmlns", "urn:foreign"}])
    wrong_rdf = NamespaceScope.new() |> NamespaceScope.enter([{"xmlns:rdf", "urn:foreign"}])
    undeclared_rdf = NamespaceScope.new() |> NamespaceScope.enter([{"xmlns:rdf", ""}])
    empty = NamespaceScope.new()

    assert Name.core_name?("a:feed", atom, :atom, "feed")
    assert Name.core_name?("feed", atom_default, :atom, "feed")
    assert Name.core_name?("feed", empty, :atom, "feed")
    assert Name.core_name?("feed", rss, :rss, "feed")
    assert Name.core_name?("item", empty, :rss, "item")
    assert Name.core_name?("channel", empty, :rdf, "channel")
    assert Name.core_name?("rdf:RDF", empty, :rdf, "RDF")
    assert Name.core_name?("r:RDF", rdf, :rdf, "RDF")
    assert Name.core_name?("RDF", rdf_default, :rdf, "RDF")
    refute Name.core_name?("feed", wrong, :atom, "feed")
    refute Name.core_name?("x:feed", empty, :atom, "feed")
    refute Name.core_name?("rdf:RDF", wrong_rdf, :rdf, "RDF")
    refute Name.core_name?("rdf:RDF", undeclared_rdf, :rdf, "RDF")
    refute Name.core_name?("x:RDF", empty, :rdf, "RDF")
  end
end
