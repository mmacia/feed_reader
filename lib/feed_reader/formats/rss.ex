defmodule FeedReader.Formats.RSS do
  @moduledoc "RSS format detection and normalization."

  @behaviour FeedReader.Format

  alias FeedReader.{Feed, Item, Language, URL, XMLResourceLimits}
  alias FeedReader.Media
  alias FeedReader.XML.NamespaceScope

  @rss1_namespace "http://purl.org/rss/1.0/"
  @media_rss_namespace "http://search.yahoo.com/mrss/"

  @impl true
  def matches_prefix?(prefix) do
    case Regex.run(~r/<rss\b([^>]*)>/is, prefix, capture: :all_but_first) do
      [attributes] ->
        not Regex.match?(~r/\bversion\s*=/is, attributes) or
          Regex.match?(
            ~r/\bversion\s*=\s*(["'])(?:0\.9(?:1|2)?|1\.0|2\.0)\1/is,
            attributes
          )

      _none ->
        false
    end
  end

  @impl true
  def id, do: :rss

  @impl true
  def handler, do: FeedReader.Formats.RSS.Handler

  @impl true
  def new_parser_state(event_sink, opts) do
    %{
      event_sink: event_sink,
      opts: opts,
      limits: XMLResourceLimits.new(opts),
      namespace_scope: NamespaceScope.new(),
      frames: [],
      channel: nil,
      normalized_feed: nil,
      feed_candidate_sequence: Media.CandidateSequence.new(),
      item_candidate_sequence: Media.CandidateSequence.new(),
      root_closed: false,
      error: nil
    }
  end

  @impl true
  def normalize_feed(state, opts) do
    case normalize_feed_result(state, opts) do
      {:ok, feed} -> feed
      {:error, _reason} -> normalize_feed_metadata(state, opts)
    end
  end

  defp normalize_feed_metadata(%{channel: channel}, opts) do
    channel = if is_map(channel), do: channel, else: %{}
    title = value(channel, "title")
    description = value(channel, "description")
    link = value(channel, "link")

    %Feed{
      title: clean_title(title) || description || link,
      description: description,
      feed_url: Keyword.get(opts, :feed_url),
      html_url: link,
      type: :rss,
      categories:
        channel
        |> Map.get("category", [])
        |> List.wrap()
        |> Enum.map(&text/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    }
  end

  def normalize_feed_result(state, opts) do
    feed = normalize_feed_metadata(state, opts)

    candidates =
      state
      |> Map.get(:feed_candidate_sequence, Media.CandidateSequence.new())

    Media.Normalizer.attach_media(
      :feed,
      feed,
      candidates,
      opts,
      &normalize_channel_image(&1, feed)
    )
  end

  @impl true
  def normalize_item(item, feed, _opts) do
    title = clean_title(value(item, "title"))
    description = value(item, "description")
    content = value(item, "content:encoded")
    link = value(item, "link")

    canonical_url = URL.resolve_root_relative(link, [feed.html_url, feed.feed_url])
    uuid = value(item, "guid") || canonical_url
    summary = description || if(is_nil(content), do: title)

    {:ok,
     %Item{
       uuid: uuid,
       title: title || clean_title(description) || canonical_url,
       content_full: content,
       content_summary: summary,
       canonical_url: canonical_url,
       author: value(item, "dc:creator") || value(item, "author"),
       published_at: published_at(value(item, "pubDate") || value(item, "dc:date")),
       language: Language.detect([title, content, description])
     }}
  end

  def normalize_item_result(item, candidate_sequence, feed, opts) do
    {:ok, item} = normalize_item(item, feed, opts)

    Media.Normalizer.attach_media(
      :item,
      item,
      candidate_sequence,
      opts,
      &normalize_item_media(&1, feed)
    )
  end

  defp normalize_enclosure(
         %Media.Candidate{name: {namespace, "enclosure"}} = candidate,
         feed
       )
       when namespace in [nil, @rss1_namespace] do
    mime_type = Media.Normalizer.normalize_image_mime_type(candidate.attributes[{nil, "type"}])
    url = candidate.attributes[{nil, "url"}] |> Media.Normalizer.normalize_media_url(feed)

    if mime_type && url do
      %Media{url: url, kind: :image, role: :enclosure, mime_type: mime_type}
    end
  end

  defp normalize_enclosure(_candidate, _feed), do: nil

  defp normalize_item_media(
         %Media.Candidate{name: {@media_rss_namespace, name}} = candidate,
         feed
       )
       when name in ["content", "thumbnail"],
       do: Media.Normalizer.normalize_media_rss_candidate(candidate, feed)

  defp normalize_item_media(candidate, feed), do: normalize_enclosure(candidate, feed)

  defp normalize_channel_image(
         %Media.Candidate{name: {namespace, "image"}, children: children},
         feed
       )
       when namespace in [nil, @rss1_namespace] do
    with url when is_binary(url) <-
           children
           |> child_value("url", namespace)
           |> Media.Normalizer.normalize_media_url(feed) do
      %Media{
        url: url,
        kind: :image,
        role: :logo,
        mime_type: nil,
        title: child_value(children, "title", namespace),
        width: children |> child_value("width", namespace) |> Media.Normalizer.parse_dimension(),
        height: children |> child_value("height", namespace) |> Media.Normalizer.parse_dimension()
      }
    end
  end

  defp normalize_channel_image(_candidate, _feed), do: nil

  defp child_value(children, local_name, namespace),
    do:
      children
      |> Map.get({namespace, local_name})
      |> List.wrap()
      |> Enum.find_value(&text/1)

  defp value(map, key), do: map |> Map.get(key) |> text()
  defp text(%{"_text" => value}), do: text(value)
  defp text(value) when is_binary(value), do: blank_to_nil(value)
  defp text(_value), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean_title(nil), do: nil
  defp clean_title(value), do: value |> HtmlSanitizeEx.strip_tags() |> blank_to_nil()

  defp published_at(nil), do: nil

  defp published_at(value) do
    case DateTimeParser.parse(value, to_utc: true) do
      {:ok, %DateTime{} = date} -> date
      _invalid -> nil
    end
  end
end
