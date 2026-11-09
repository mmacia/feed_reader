defmodule FeedReader.Media.SizeTest do
  use ExUnit.Case, async: true

  alias FeedReader.{Item, Media}

  test "counts the complete embedded media encoding, including entry overhead" do
    media = media("https://example.com/image.jpg")

    lower_bound = Media.Size.add(0, media)

    assert lower_bound == :erlang.external_size(media) - 1
    assert lower_bound == byte_size(:erlang.term_to_binary(media)) - 1
    assert lower_bound > byte_size(media.url)
    assert lower_bound <= byte_size(:erlang.term_to_binary(%Item{media: [media]}))
  end

  test "accounts for each media entry and expanded URL value incrementally" do
    first = media("https://example.com/image.jpg")
    expanded = media("https://example.com/a/long/feed/base/image.jpg")

    lower_bound = Media.Size.add(0, first)
    lower_bound = Media.Size.add(lower_bound, expanded)

    assert lower_bound == :erlang.external_size(first) + :erlang.external_size(expanded) - 2
    assert lower_bound <= byte_size(:erlang.term_to_binary(%Item{media: [first, expanded]}))
    assert lower_bound > byte_size(first.url) + byte_size(expanded.url)
  end

  defp media(url) do
    %Media{url: url, kind: :image, role: :content, mime_type: "image/jpeg", title: "image"}
  end
end
