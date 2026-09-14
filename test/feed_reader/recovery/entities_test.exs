defmodule FeedReader.Recovery.EntitiesTest do
  use ExUnit.Case, async: true

  alias FeedReader.Recovery.Entities

  test "preserves valid named and numeric entities" do
    xml = "&amp; &lt; &gt; &quot; &apos; &#169; &#x1F600;"

    assert normalize([xml]) == xml
  end

  test "escapes raw and invalid entity references" do
    assert normalize(["A & B &unknown; C &not-an-entity D"]) ==
             "A &amp; B &amp;unknown; C &amp;not-an-entity D"
  end

  test "preserves ampersands inside CDATA" do
    chunks = ["<![C", "DATA[<p>A & B</p>]]>"]

    assert normalize(chunks) == "<![CDATA[<p>A & B</p>]]>"
  end

  test "preserves ampersands inside comments" do
    chunks = ["<!-- source: A &", " B -->"]

    assert normalize(chunks) == "<!-- source: A & B -->"
  end

  test "handles an entity split across chunks" do
    assert normalize(["A &am", "p; B &#", "169; C"]) == "A &amp; B &#169; C"
  end

  test "handles CDATA and comment terminators split across chunks" do
    chunks = ["<![CDATA[A & B]", "]><!-- C & D -", "->E & F"]

    assert normalize(chunks) == "<![CDATA[A & B]]><!-- C & D -->E &amp; F"
  end

  defp normalize(chunks), do: chunks |> Entities.normalize() |> Enum.join()
end
