defmodule FeedReader.XMLResourceLimitsTest do
  use ExUnit.Case, async: true

  alias FeedReader.XMLResourceLimits

  test "uses finite defaults and falls back for invalid limits" do
    defaults = XMLResourceLimits.new()

    assert defaults.max_xml_events == 1_000_000
    assert defaults.max_xml_depth == 256
    assert defaults.max_attributes_per_element == 128
    assert defaults.max_attribute_bytes == 65_536
    assert defaults.max_feed_metadata_bytes == 1_048_576
    assert defaults.max_item_bytes == 4_194_304

    limits = XMLResourceLimits.new(max_xml_events: -1, max_item_bytes: :unbounded)
    assert limits.max_xml_events == defaults.max_xml_events
    assert limits.max_item_bytes == defaults.max_item_bytes
  end

  test "rejects unsupported events and malformed SAX payloads" do
    limits = XMLResourceLimits.new()

    assert {:error, :invalid_sax_event} =
             XMLResourceLimits.account_event(limits, :processing_instruction, "data")

    assert {:error, :invalid_sax_event} =
             XMLResourceLimits.account_event(limits, :start_element, {"root", [{"attr", 1}]})

    assert {:error, :invalid_sax_event} =
             XMLResourceLimits.account_event(limits, :end_element, "root")
  end

  test "counts SAX events and rejects depth before accepting another element" do
    limits = XMLResourceLimits.new(max_xml_events: 3, max_xml_depth: 1)
    assert {:ok, limits} = XMLResourceLimits.account_event(limits, :start_document, [])
    assert {:ok, limits} = XMLResourceLimits.account_event(limits, :start_element, {"root", []})

    assert {:error, {:resource_limit, :max_xml_depth, 1}} =
             XMLResourceLimits.account_event(limits, :start_element, {"nested", []})

    assert {:ok, limits} = XMLResourceLimits.account_event(limits, :end_element, "root")

    assert {:error, {:resource_limit, :max_xml_events, 3}} =
             XMLResourceLimits.account_event(limits, :end_document, [])
  end

  test "bounds per-element attribute count and attribute byte length" do
    limits = XMLResourceLimits.new(max_attributes_per_element: 1, max_attribute_bytes: 5)

    assert {:error, {:resource_limit, :max_attributes_per_element, 1}} =
             XMLResourceLimits.account_event(
               limits,
               :start_element,
               {"x", [{"a", "1"}, {"b", "2"}]}
             )

    limits = XMLResourceLimits.new(max_attribute_bytes: 5)

    assert {:error, {:resource_limit, :max_attribute_bytes, 5}} =
             XMLResourceLimits.account_event(limits, :start_element, {"x", [{"a", "12345"}]})
  end

  test "charges SAX text and attributes to the active metadata or item budget" do
    limits = XMLResourceLimits.new(max_feed_metadata_bytes: 4, max_item_bytes: 5)
    limits = XMLResourceLimits.set_scope(limits, :feed)

    assert {:error, {:resource_limit, :max_feed_metadata_bytes, 4}} =
             XMLResourceLimits.account_event(limits, :start_element, {"x", [{"a", "123"}]})

    assert {:ok, limits} = XMLResourceLimits.account_event(limits, :characters, "feed")

    assert {:error, {:resource_limit, :max_feed_metadata_bytes, 4}} =
             XMLResourceLimits.account_event(limits, :characters, "!")

    limits = XMLResourceLimits.set_scope(limits, :item)
    assert {:ok, limits} = XMLResourceLimits.account_event(limits, :start_element, {"x", []})
    assert {:ok, limits} = XMLResourceLimits.account_event(limits, :cdata, "item")

    assert {:error, {:resource_limit, :max_item_bytes, 5}} =
             XMLResourceLimits.account_event(limits, :characters, "!")

    limits = XMLResourceLimits.set_scope(limits, :item)
    assert {:ok, _limits} = XMLResourceLimits.account_event(limits, :characters, "fresh")
  end
end
