defmodule FeedReader.MediaTest do
  use ExUnit.Case, async: true

  alias FeedReader.Media

  test "constructs media with optional fields defaulting to nil" do
    media = %Media{url: "https://example.com/image.jpg", kind: :image, role: :thumbnail}

    assert %Media{
             url: "https://example.com/image.jpg",
             kind: :image,
             role: :thumbnail,
             mime_type: nil,
             title: nil,
             width: nil,
             height: nil
           } = media
  end

  test "stores supplied media metadata" do
    media = %Media{
      url: "https://example.com/image.jpg",
      kind: :image,
      role: :content,
      mime_type: "image/jpeg",
      title: "Article image",
      width: 640,
      height: 480
    }

    assert media.mime_type == "image/jpeg"
    assert media.title == "Article image"
    assert media.width == 640
    assert media.height == 480
  end

  test "requires the URL, kind, and role" do
    required = [url: "https://example.com/image.jpg", kind: :image, role: :content]

    for field <- [:url, :kind, :role] do
      assert_raise ArgumentError, fn -> struct!(Media, Keyword.delete(required, field)) end
    end

    assert %Media{} = struct!(Media, required)
  end
end
