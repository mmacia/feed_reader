defmodule FeedReader.Formats.RDF do
  @moduledoc "RDF Site Summary format detection and normalization."
  @behaviour FeedReader.Format

  alias FeedReader.{Feed, Item, Language, Media, URL, XMLResourceLimits}

  alias FeedReader.XML.NamespaceScope

  @rdf_namespace "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
  @rss1_namespace "http://purl.org/rss/1.0/"
  @media_rss_namespace "http://search.yahoo.com/mrss/"

  @impl true
  def matches_prefix?(prefix), do: Regex.match?(~r/<rdf:rdf\b/is, prefix)

  @impl true
  def id, do: :rdf

  @impl true
  def handler, do: FeedReader.Formats.RDF.Handler

  @impl true
  def new_parser_state(event_sink, opts),
    do: %{
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

  @impl true
  def normalize_feed(state, opts) do
    case normalize_feed_result(state, opts) do
      {:ok, feed} -> feed
      {:error, _reason} -> normalize_feed_metadata(state, opts)
    end
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

  defp normalize_feed_metadata(%{channel: channel}, opts) do
    channel = if is_map(channel), do: channel, else: %{}
    title = text(channel["title"])
    description = text(channel["description"])
    link = text(channel["link"])

    %Feed{
      title: title || description || link,
      description: description,
      feed_url: Keyword.get(opts, :feed_url),
      html_url: link,
      type: :rdf,
      categories:
        channel
        |> Map.get("dc:subject", [])
        |> List.wrap()
        |> Enum.map(&text/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    }
  end

  defp normalize_channel_image(
         %Media.Candidate{name: {namespace, "image"}, attributes: attributes, children: children},
         feed
       )
       when namespace in [nil, @rss1_namespace] do
    with url when is_binary(url) <-
           attributes[{@rdf_namespace, "resource"}]
           |> Media.Normalizer.normalize_media_url(feed) do
      %Media{
        url: url,
        kind: :image,
        role: :logo,
        mime_type: Media.Normalizer.normalize_image_mime_type(attributes[{nil, "type"}]),
        title: candidate_value(children, "title", namespace),
        width:
          children |> candidate_value("width", namespace) |> Media.Normalizer.parse_dimension(),
        height:
          children |> candidate_value("height", namespace) |> Media.Normalizer.parse_dimension()
      }
    end
  end

  defp normalize_channel_image(_candidate, _feed), do: nil

  defp candidate_value(children, local_name, namespace),
    do: children |> Map.get({namespace, local_name}) |> List.wrap() |> Enum.find_value(&text/1)

  @impl true
  def normalize_item(raw, feed, _opts) do
    title = raw |> Map.get("title") |> text() |> clean()
    description = text(raw["description"])
    content = text(raw["content:encoded"])

    canonical =
      raw
      |> Map.get("link")
      |> text()
      |> URL.resolve_root_relative([feed.html_url, feed.feed_url])

    {:ok,
     %Item{
       uuid: text(raw["guid"]) || text(raw["id"]) || canonical,
       title: title,
       content_full: content,
       content_summary: description,
       canonical_url: canonical,
       author: text(raw["dc:creator"]),
       published_at: published_at(text(raw["dc:date"])),
       language: Language.detect([title, content, description])
     }}
  end

  def normalize_item_result(raw, candidate_sequence, feed, opts) do
    {:ok, item} = normalize_item(raw, feed, opts)

    Media.Normalizer.attach_media(
      :item,
      item,
      candidate_sequence,
      opts,
      &normalize_item_media(&1, feed)
    )
  end

  defp normalize_item_media(
         %Media.Candidate{name: {@media_rss_namespace, name}} = candidate,
         feed
       )
       when name in ["content", "thumbnail"],
       do: Media.Normalizer.normalize_media_rss_candidate(candidate, feed)

  defp normalize_item_media(_candidate, _feed), do: nil

  defp text(%{"_text" => value}), do: text(value)

  defp text(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp text(_value), do: nil
  defp clean(nil), do: nil
  defp clean(value), do: value |> HtmlSanitizeEx.strip_tags() |> text()

  defp published_at(nil), do: DateTime.utc_now(:second)

  defp published_at(value) do
    case DateTimeParser.parse(value, to_utc: true) do
      {:ok, %DateTime{} = date} -> date
      _invalid -> DateTime.utc_now(:second)
    end
  end
end
