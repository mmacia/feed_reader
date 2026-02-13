defmodule FeedReader.ItemTest do
  use ExUnit.Case, async: true

  alias FeedReader.Item

  test "uses empty normalized item defaults" do
    assert %Item{
             uuid: nil,
             title: nil,
             content_full: nil,
             content_summary: nil,
             language: nil,
             published_at: nil,
             canonical_url: nil,
             alternate: %{},
             author: nil,
             extensions: %{}
           } = %Item{}
  end

  test "stores normalized content and extension metadata" do
    published_at = ~U[2026-01-01 12:00:00Z]

    item = %Item{
      uuid: "item-1",
      title: "Example item",
      content_summary: "Summary",
      language: :en,
      published_at: published_at,
      canonical_url: "https://example.com/item-1",
      author: "Author",
      extensions: %{"urn:example" => %{"rating" => "safe"}}
    }

    assert item.uuid == "item-1"
    assert item.published_at == published_at
    assert item.extensions["urn:example"]["rating"] == "safe"
  end
end
