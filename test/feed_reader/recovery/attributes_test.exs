defmodule FeedReader.Recovery.AttributesTest do
  use ExUnit.Case, async: true

  alias FeedReader.Recovery.Attributes

  test "preserves valid attributes" do
    xml = ~s(<link href="https://example.com" rel="alternate" />)

    assert normalize([xml]) == xml
  end

  test "repairs literal double quotes inside an attribute value" do
    xml = ~s(<link title="How to "Sustain Heroku"" />)

    assert normalize([xml]) == ~s(<link title="How to &quot;Sustain Heroku&quot;" />)
  end

  test "repairs malformed attributes split across chunks" do
    chunks = [~s(<link title="How to "Sustain), ~s( Heroku"" />)]

    assert normalize(chunks) == ~s(<link title="How to &quot;Sustain Heroku&quot;" />)
  end

  test "preserves empty attributes and single-quoted attributes" do
    xml = ~s(<source url="" label='A "quoted" source' />)

    assert normalize([xml]) == xml
  end

  test "does not repair quotes in CDATA or comments" do
    xml = ~s(<![CDATA[<p title="A "quoted" value">Text</p>]]><!-- A "quoted" comment -->)

    assert normalize([xml]) == xml
  end

  test "does not repair across adjacent elements" do
    xml = ~s(<source url="">Source</source><category domain="region">News</category>)

    assert normalize([xml]) == xml
  end

  test "preserves text outside markup" do
    assert normalize(["before ", ~s(<item title="Story" />), " after"]) ==
             ~s(before <item title="Story" /> after)
  end

  defp normalize(chunks), do: chunks |> Attributes.normalize() |> Enum.join()
end
