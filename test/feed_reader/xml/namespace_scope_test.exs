defmodule FeedReader.XML.NamespaceScopeTest do
  use ExUnit.Case, async: true

  alias FeedReader.XML.NamespaceScope

  test "tracks default and prefixed declarations with nested rebinding" do
    root =
      NamespaceScope.new()
      |> NamespaceScope.enter([
        {"xmlns", "urn:root"},
        {"xmlns:media", "urn:media"}
      ])

    assert NamespaceScope.uri(root, "") == "urn:root"
    assert NamespaceScope.uri(root, "media") == "urn:media"

    nested =
      NamespaceScope.enter(root, [
        {"xmlns", "urn:nested"},
        {"xmlns:media", "urn:nested-media"}
      ])

    assert NamespaceScope.uri(nested, "") == "urn:nested"
    assert NamespaceScope.uri(nested, "media") == "urn:nested-media"

    restored = NamespaceScope.leave(nested)
    assert NamespaceScope.uri(restored, "") == "urn:root"
    assert NamespaceScope.uri(restored, "media") == "urn:media"
  end

  test "restores declarations after namespace undeclaration and ignores other attributes" do
    parent = NamespaceScope.new() |> NamespaceScope.enter([{"xmlns:media", "urn:media"}])

    child =
      NamespaceScope.enter(parent, [
        {"xmlns", ""},
        {"xmlns:media", ""},
        {"id", "item-1"}
      ])

    assert NamespaceScope.uri(child, "") == nil
    assert NamespaceScope.uri(child, "media") == nil
    assert NamespaceScope.uri(child, "unknown") == nil

    restored = NamespaceScope.leave(child)
    assert NamespaceScope.uri(restored, "media") == "urn:media"
    assert NamespaceScope.uri(NamespaceScope.leave(NamespaceScope.new()), "") == nil
  end
end
