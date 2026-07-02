defmodule FeedReader.Formats.Atom do
  @moduledoc "Atom feed detection and normalization."
  @behaviour FeedReader.Format
  alias FeedReader.{Feed, Item, Language, URL, XMLResourceLimits}

  @impl true
  def matches_prefix?(prefix), do: Regex.match?(~r/<feed\b/is, prefix)
  @impl true
  def id, do: :atom
  @impl true
  def handler, do: FeedReader.Formats.Atom.Handler
  @impl true
  def new_parser_state(sink, opts),
    do: %{
      event_sink: sink,
      opts: opts,
      limits: XMLResourceLimits.new(opts),
      frames: [],
      feed: nil,
      error: nil
    }

  @impl true
  def normalize_feed(%{feed: data}, opts) do
    data = if is_map(data), do: data, else: %{}
    title = text(data["title"])
    description = text(data["subtitle"])
    links = List.wrap(data["link"])
    link = find_link(links)
    id = text(data["id"])

    %Feed{
      title: title || description || link || id,
      description: description,
      feed_url: Keyword.get(opts, :feed_url),
      html_url: link || if(valid_url?(id), do: id),
      type: :atom,
      categories: categories(data)
    }
  end

  @impl true
  def normalize_item(raw, feed, _opts) do
    title = raw |> Map.get("title") |> text() |> clean()
    content = raw |> Map.get("content") |> content()
    summary = raw |> Map.get("summary") |> content() || if(is_nil(content), do: title)

    canonical =
      raw
      |> Map.get("link")
      |> List.wrap()
      |> find_link()
      |> URL.resolve_root_relative([feed.html_url, feed.feed_url])

    author = raw |> Map.get("author") |> author()

    date = text(raw["published"]) || text(raw["updated"])

    {:ok,
     %Item{
       uuid: text(raw["id"]) || canonical,
       title: title || canonical,
       content_full: content,
       content_summary: summary,
       canonical_url: canonical,
       author: author,
       published_at: published_at(date),
       language: Language.detect([title, content, summary])
     }}
  end

  defp categories(data),
    do:
      for(%{"term" => value} <- List.wrap(data["category"]), value = text(value), do: value)
      |> Enum.uniq()

  defp text(%{"_text" => value}), do: text(value)
  defp text(value) when is_binary(value), do: blank_to_nil(value)
  defp text(_value), do: nil
  defp content(nil), do: nil

  defp content(%{"type" => "xhtml", "_markup" => markup}),
    do: markup |> IO.iodata_to_binary() |> blank_to_nil()

  defp content(value), do: text(value)

  defp author(value) do
    value
    |> List.wrap()
    |> Enum.map(&author_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> blank_to_nil()
  end

  defp author_name(%{"name" => name}), do: text(name)
  defp author_name(value), do: text(value)

  defp find_link(links) do
    case Enum.find(links, &((is_map(&1) and &1["href"]) && &1["rel"] in [nil, "alternate"])) do
      %{"href" => href} -> clean(href)
      _ -> nil
    end
  end

  defp valid_url?(url),
    do: is_binary(url) and url |> URI.parse() |> then(&(!is_nil(&1.scheme) and !is_nil(&1.host)))

  defp clean(nil), do: nil
  defp clean(value), do: value |> HtmlSanitizeEx.strip_tags() |> blank_to_nil()
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp published_at(nil), do: nil

  defp published_at(value), do: DateTimeParser.parse(value, to_utc: true) |> parsed_date()
  defp parsed_date({:ok, %DateTime{} = date}), do: date
  defp parsed_date(_result), do: nil
end
