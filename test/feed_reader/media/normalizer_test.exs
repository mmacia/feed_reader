defmodule FeedReader.Media.NormalizerTest do
  use ExUnit.Case, async: true

  alias FeedReader.{Feed, Item, Media}
  alias FeedReader.Media.CandidateSequence

  @media_rss "http://search.yahoo.com/mrss/"

  test "trims media URLs and resolves single-slash root-relative references" do
    feed = %Feed{
      html_url: "https://example.com/articles/story",
      feed_url: "https://feeds.example.org/rss.xml"
    }

    assert Media.Normalizer.normalize_media_url("  https://cdn.example/image.jpg  ", feed) ==
             "https://cdn.example/image.jpg"

    assert Media.Normalizer.normalize_media_url("  /images/photo.jpg  ", feed) ==
             "https://example.com/images/photo.jpg"

    assert Media.Normalizer.normalize_media_url(" images/photo.jpg ", feed) == "images/photo.jpg"
    assert Media.Normalizer.normalize_media_url(" ?size=large ", feed) == "?size=large"
    assert Media.Normalizer.normalize_media_url(" #preview ", feed) == "#preview"

    assert Media.Normalizer.normalize_media_url(" //cdn.example/image.jpg ", feed) ==
             "//cdn.example/image.jpg"
  end

  test "resolves media URLs with the first available absolute feed base" do
    feed = %Feed{html_url: "/relative/page", feed_url: "https://example.com/feed.xml"}

    assert Media.Normalizer.normalize_media_url("/images/photo.jpg", feed) ==
             "https://example.com/images/photo.jpg"
  end

  test "preserves root-relative media URLs when no absolute feed base exists" do
    feed = %Feed{html_url: "/relative/page", feed_url: nil}

    assert Media.Normalizer.normalize_media_url(" /images/photo.jpg ", feed) ==
             "/images/photo.jpg"

    assert Media.Normalizer.normalize_media_url("/images/photo.jpg", nil) ==
             "/images/photo.jpg"
  end

  test "omits missing or blank media URLs" do
    assert Media.Normalizer.normalize_media_url(nil, %Feed{}) == nil
    assert Media.Normalizer.normalize_media_url(" \n\t ", %Feed{}) == nil
    assert Media.Normalizer.normalize_media_url(123, %Feed{}) == nil
  end

  test "normalizes image MIME types without parameters" do
    assert Media.Normalizer.normalize_image_mime_type(" IMAGE/JPEG ; charset=binary ") ==
             "image/jpeg"

    assert Media.Normalizer.normalize_image_mime_type("image/svg+xml") == "image/svg+xml"
    assert Media.Normalizer.normalize_image_mime_type("image/*") == "image/*"
    assert Media.Normalizer.image_mime_type?("Image/PNG; q=0.8")
  end

  test "rejects non-image and malformed MIME types" do
    for mime_type <- [nil, 123, "", "image", "image/", "image/png/extra", "image/png extra"] do
      assert Media.Normalizer.normalize_image_mime_type(mime_type) == nil
      refute Media.Normalizer.image_mime_type?(mime_type)
    end

    assert Media.Normalizer.normalize_image_mime_type("audio/mpeg") == nil
    refute Media.Normalizer.image_mime_type?("text/html; charset=utf-8")
  end

  test "parses only non-negative integer dimensions" do
    assert Media.Normalizer.parse_dimension("320") == 320
    assert Media.Normalizer.parse_dimension("  0  ") == 0
    assert Media.Normalizer.parse_dimension(240) == 240

    for dimension <- [nil, "", "  ", "-1", "1.5", "100px", -1, 1.5, :invalid] do
      assert Media.Normalizer.parse_dimension(dimension) == nil
    end
  end

  test "normalizes Media RSS content when image identity is unambiguous" do
    feed = %Feed{html_url: "https://example.com/articles/story"}

    candidates = [
      {%{"medium" => "IMAGE"}, nil},
      {%{"type" => " IMAGE/JPEG ; q=0.8 "}, "image/jpeg"},
      {%{"medium" => " image ", "type" => "image/png"}, "image/png"},
      {%{"medium" => "   ", "type" => "image/gif"}, "image/gif"}
    ]

    for {attributes, mime_type} <- candidates do
      candidate = media_rss_candidate("content", Map.put(attributes, "url", " /images/a.jpg "))

      assert %Media{
               url: "https://example.com/images/a.jpg",
               role: :content,
               mime_type: ^mime_type
             } = Media.Normalizer.normalize_media_rss_candidate(candidate, feed)
    end
  end

  test "omits Media RSS content with missing or conflicting image declarations" do
    invalid_attributes = [
      %{},
      %{"medium" => "video", "type" => "image/jpeg"},
      %{"medium" => "image", "type" => "audio/mpeg"}
    ]

    for attributes <- invalid_attributes do
      candidate = media_rss_candidate("content", Map.put(attributes, "url", "image.jpg"))
      assert Media.Normalizer.normalize_media_rss_candidate(candidate, %Feed{}) == nil
    end
  end

  test "normalizes Media RSS thumbnails by element semantics and retains image MIME types only" do
    feed = %Feed{html_url: "https://example.com/feed"}

    image_thumbnail =
      media_rss_candidate(
        "thumbnail",
        %{"url" => "/thumb.jpg", "type" => " IMAGE/WEBP ; quality=high ", "width" => "320"},
        "Thumbnail title"
      )

    assert %Media{
             url: "https://example.com/thumb.jpg",
             kind: :image,
             role: :thumbnail,
             mime_type: "image/webp",
             title: "Thumbnail title",
             width: 320
           } = Media.Normalizer.normalize_media_rss_candidate(image_thumbnail, feed)

    non_image_thumbnail =
      media_rss_candidate("thumbnail", %{"url" => "thumb.jpg", "type" => "audio/mpeg"})

    assert %Media{mime_type: nil, role: :thumbnail} =
             Media.Normalizer.normalize_media_rss_candidate(non_image_thumbnail, feed)
  end

  test "omits Media RSS candidates without a usable URL or outside the Media RSS namespace" do
    assert Media.Normalizer.normalize_media_rss_candidate(
             media_rss_candidate("content", %{"medium" => "image", "url" => " \n "}),
             %Feed{}
           ) == nil

    group_candidate = %Media.Candidate{name: {@media_rss, "group"}}
    assert Media.Normalizer.normalize_media_rss_candidate(group_candidate, %Feed{}) == nil
  end

  test "accepts the exact lower-bound budget and resets accounting per event" do
    media = media("https://example.com/image.jpg")
    limit = Media.Size.add(0, media)
    normalize = fn :image -> media end

    for _ <- 1..2 do
      assert {:ok, [^media]} =
               Media.Normalizer.reduce([:image], [max_queue_bytes: limit], normalize)
    end

    assert Media.Normalizer.reduce([:image], [max_queue_bytes: limit - 1], normalize) ==
             {:error, {:resource_limit, :max_queue_bytes, limit - 1}}
  end

  test "attaches media against the matching feed or item event budget" do
    media = media("https://example.com/image.jpg")
    {sequence, position} = CandidateSequence.start(CandidateSequence.new())
    sequence = CandidateSequence.complete(sequence, position, :image)
    media_size = Media.Size.add(0, media)

    for {event, result} <- [
          {:feed, %Feed{title: "News"}},
          {:item, %Item{title: "Story"}}
        ] do
      base_size = :erlang.external_size({event, result})
      limit = base_size - 1 + media_size

      assert {:ok, %{media: [^media]}} =
               Media.Normalizer.attach_media(
                 event,
                 result,
                 sequence,
                 [max_queue_bytes: limit],
                 fn :image -> media end
               )

      under_limit = limit - 1

      assert {:error, {:resource_limit, :max_queue_bytes, ^under_limit}} =
               Media.Normalizer.attach_media(
                 event,
                 result,
                 sequence,
                 [max_queue_bytes: under_limit],
                 fn :image -> media end
               )
    end
  end

  test "filtered and blank candidates do not consume the budget" do
    first = media("https://example.com/image.jpg")
    second = media("https://example.com/second.jpg")

    normalize = fn
      :filtered -> :skip
      :blank -> nil
      :first -> first
      :second -> second
    end

    limit = Media.Size.add(Media.Size.add(0, first), second)

    assert {:ok, [^first, ^second]} =
             Media.Normalizer.reduce(
               [:filtered, :blank, :first, :second],
               [max_queue_bytes: limit],
               normalize
             )
  end

  test "stops normalizing candidates as soon as the bound exceeds the budget" do
    first = media("https://example.com/first.jpg")
    second = media("https://example.com/second.jpg")
    limit = Media.Size.add(0, first)

    normalize = fn candidate ->
      Process.put(:normalized_candidates, [candidate | Process.get(:normalized_candidates, [])])
      %{filtered: nil, first: first, second: second, unvisited: :never}[candidate]
    end

    assert {:error, {:resource_limit, :max_queue_bytes, ^limit}} =
             Media.Normalizer.reduce(
               [:filtered, :first, :second, :unvisited],
               [max_queue_bytes: limit],
               normalize
             )

    assert Enum.reverse(Process.get(:normalized_candidates)) == [:filtered, :first, :second]
  end

  test "stops with the normalization resource-limit error" do
    state = %{error: nil}

    assert {:stop, %{error: {:resource_limit, :max_queue_bytes, 10}}} =
             Media.Normalizer.emit_item_result(
               {:error, {:resource_limit, :max_queue_bytes, 10}},
               state
             )
  end

  test "emits a successfully normalized item" do
    caller = self()
    item = %{title: "Article"}
    state = %{event_sink: fn event -> send(caller, {:event, event}) end}

    assert {:ok, ^state} = Media.Normalizer.emit_item_result({:ok, item}, state)
    assert_receive {:event, {:item, ^item}}
  end

  defp media(url), do: %Media{url: url, kind: :image, role: :content}

  defp media_rss_candidate(name, attributes, title \\ nil),
    do: %Media.Candidate{
      name: {@media_rss, name},
      attributes: Map.new(attributes, fn {name, value} -> {{nil, name}, value} end),
      title: title
    }
end
