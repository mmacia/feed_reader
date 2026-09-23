defmodule FeedReader.Formats.RSS do
  @moduledoc "RSS 2.0 format detection and normalization."

  @behaviour FeedReader.Format

  alias FeedReader.{Feed, Item, Language, URL, XMLResourceLimits}

  @impl true
  def matches_prefix?(prefix) do
    Regex.match?(~r/<rss\b[^>]*\bversion\s*=\s*(["'])(?:0\.9(?:1|2)?|2\.0)\1/is, prefix)
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
      frames: [],
      channel: nil,
      root_closed: false,
      error: nil
    }
  end

  @impl true
  def normalize_feed(%{channel: channel}, opts) do
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
