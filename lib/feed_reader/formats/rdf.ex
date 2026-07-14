defmodule FeedReader.Formats.RDF do
  @moduledoc "RDF Site Summary format detection and normalization."
  @behaviour FeedReader.Format

  alias FeedReader.{Feed, Item, Language, URL, XMLResourceLimits}

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
      frames: [],
      channel: nil,
      root_closed: false,
      error: nil
    }

  @impl true
  def normalize_feed(%{channel: channel}, opts) do
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
