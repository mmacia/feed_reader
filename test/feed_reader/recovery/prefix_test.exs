defmodule FeedReader.Recovery.PrefixTest do
  use ExUnit.Case, async: true

  alias FeedReader.Recovery.Prefix

  test "removes a BOM and leading XML whitespace" do
    assert normalize([<<0xEF, 0xBB, 0xBF, 13, 10, 9, 32>>, "<rss/>"]) == "<rss/>"
  end

  test "removes a BOM split across chunks" do
    assert normalize([<<0xEF>>, <<0xBB>>, <<0xBF>>, " \n", "<rss/>"]) == "<rss/>"
  end

  test "removes leading whitespace split across chunks" do
    assert normalize(["\r", "\n", "\t", " ", "<rss/>"]) == "<rss/>"
  end

  test "preserves content that does not have a removable prefix" do
    assert normalize(["<rss/>", "<tail/>"]) == "<rss/><tail/>"
  end

  test "returns an empty stream for empty or whitespace-only input" do
    assert normalize([]) == ""
    assert normalize([" ", "\n", "\r\t"]) == ""
  end

  defp normalize(chunks), do: chunks |> Prefix.normalize() |> Enum.join()
end
