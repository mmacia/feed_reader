defmodule FeedReader.Media.Normalizer do
  @moduledoc false

  alias FeedReader.{Feed, Item, Media, Options, URL}
  alias FeedReader.Media.CandidateSequence

  @media_rss_namespace "http://search.yahoo.com/mrss/"
  # Matches MIME subtypes such as "svg+xml".
  @mime_token ~r/\A[!#$%&'*+.^_`|~0-9a-z-]+\z/

  @doc "Trims a media URL and resolves single-slash root-relative references."
  @spec normalize_media_url(String.t() | nil, Feed.t() | nil) :: String.t() | nil
  def normalize_media_url(url, feed) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      "//" <> _ = trimmed -> trimmed
      "/" <> _ = trimmed -> URL.resolve_root_relative(trimmed, feed_bases(feed))
      trimmed -> trimmed
    end
  end

  def normalize_media_url(_url, _feed), do: nil

  @doc "Returns a normalized image MIME type, ignoring parameters, or `nil`."
  @spec normalize_image_mime_type(String.t() | nil) :: String.t() | nil
  def normalize_image_mime_type(mime_type) when is_binary(mime_type) do
    [type_subtype | _parameters] = String.split(mime_type, ";", parts: 2)
    type_subtype = type_subtype |> String.trim() |> String.downcase()

    case String.split(type_subtype, "/", parts: 2) do
      ["image", subtype] ->
        if Regex.match?(@mime_token, subtype), do: type_subtype

      _other_type ->
        nil
    end
  end

  def normalize_image_mime_type(_mime_type), do: nil

  @doc "Returns whether a MIME type identifies an image."
  @spec image_mime_type?(term()) :: boolean()
  def image_mime_type?(mime_type), do: not is_nil(normalize_image_mime_type(mime_type))

  @doc "Parses a non-negative integer dimension, returning `nil` when invalid."
  @spec parse_dimension(term()) :: non_neg_integer() | nil
  def parse_dimension(dimension) when is_integer(dimension) and dimension >= 0, do: dimension

  def parse_dimension(dimension) when is_binary(dimension) do
    case Integer.parse(String.trim(dimension)) do
      {value, ""} when value >= 0 -> value
      _invalid -> nil
    end
  end

  def parse_dimension(_dimension), do: nil

  @doc "Normalizes an eligible Media RSS content or thumbnail candidate."
  @spec normalize_media_rss_candidate(Media.Candidate.t(), Feed.t() | nil) :: Media.t() | nil
  def normalize_media_rss_candidate(
        %Media.Candidate{name: {@media_rss_namespace, "content"}} = candidate,
        feed
      ) do
    case content_mime_type(candidate) do
      {:ok, mime_type} -> media_rss_resource(candidate, :content, mime_type, feed)
      :skip -> nil
    end
  end

  def normalize_media_rss_candidate(
        %Media.Candidate{name: {@media_rss_namespace, "thumbnail"}} = candidate,
        feed
      ) do
    mime_type = normalize_image_mime_type(attribute(candidate, "type"))
    media_rss_resource(candidate, :thumbnail, mime_type, feed)
  end

  def normalize_media_rss_candidate(_candidate, _feed), do: nil

  @doc """
  Reduces candidates within the event queue budget, counting only emitted media.
  Callbacks return `%Media{}` or `nil`/`:skip`. Each call starts at zero and halts
  on the first over-budget value. The exact event-size check remains authoritative.
  """
  @spec reduce(Enumerable.t(), keyword(), (term() -> Media.t() | :skip | nil)) ::
          {:ok, [Media.t()]} | {:error, {:resource_limit, :max_queue_bytes, non_neg_integer()}}
  def reduce(candidates, opts, normalize_candidate) when is_function(normalize_candidate, 1) do
    limit = Options.queue_limit(opts)

    candidates
    |> Enum.reduce_while({:ok, [], 0}, fn candidate, acc ->
      reduce_candidate(candidate, acc, limit, normalize_candidate)
    end)
    |> case do
      {:ok, media, _size} -> {:ok, Enum.reverse(media)}
      {:error, _reason} = error -> error
    end
  end

  @doc "Adds normalized media to a feed or item within its event queue budget."
  @spec attach_media(
          :feed | :item,
          Feed.t() | Item.t(),
          CandidateSequence.t(),
          keyword(),
          (term() -> Media.t() | :skip | nil)
        ) ::
          {:ok, Feed.t() | Item.t()}
          | {:error, {:resource_limit, :max_queue_bytes, non_neg_integer()}}
  def attach_media(event, result, candidate_sequence, opts, normalize_candidate)
      when event in [:feed, :item] and is_function(normalize_candidate, 1) do
    limit = Options.queue_limit(opts)
    base_size = :erlang.external_size({event, result})
    media_limit = max(0, limit - base_size + 1)
    candidates = CandidateSequence.finalize(candidate_sequence)

    case reduce(
           candidates,
           Keyword.put(opts, :max_queue_bytes, media_limit),
           normalize_candidate
         ) do
      {:ok, media} -> {:ok, %{result | media: media}}
      {:error, _reason} -> {:error, {:resource_limit, :max_queue_bytes, limit}}
    end
  end

  @doc false
  def emit_item_result({:ok, item}, state) do
    state.event_sink.({:item, item})
    {:ok, state}
  end

  def emit_item_result({:error, reason}, state), do: {:stop, %{state | error: reason}}

  defp feed_bases(%Feed{html_url: html_url, feed_url: feed_url}), do: [html_url, feed_url]
  defp feed_bases(_feed), do: []

  defp content_mime_type(candidate) do
    medium = candidate |> attribute("medium") |> normalize_medium()
    raw_mime_type = attribute(candidate, "type")
    mime_type = normalize_image_mime_type(raw_mime_type)

    cond do
      not is_nil(medium) and medium != "image" -> :skip
      not is_nil(raw_mime_type) and is_nil(mime_type) -> :skip
      medium == "image" -> {:ok, mime_type}
      is_nil(medium) and not is_nil(mime_type) -> {:ok, mime_type}
      true -> :skip
    end
  end

  defp media_rss_resource(candidate, role, mime_type, feed) do
    url = candidate |> attribute("url") |> normalize_media_url(feed)

    if is_nil(url) do
      nil
    else
      %Media{
        url: url,
        kind: :image,
        role: role,
        mime_type: mime_type,
        title: candidate.title,
        width: candidate |> attribute("width") |> parse_dimension(),
        height: candidate |> attribute("height") |> parse_dimension()
      }
    end
  end

  defp attribute(%Media.Candidate{attributes: attributes}, name),
    do: Map.get(attributes, {nil, name})

  defp normalize_medium(medium) when is_binary(medium) do
    case String.trim(medium) |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_medium(_medium), do: nil

  defp reduce_candidate(candidate, {:ok, media, size}, limit, normalize_candidate) do
    case normalize_candidate.(candidate) do
      nil -> {:cont, {:ok, media, size}}
      :skip -> {:cont, {:ok, media, size}}
      %Media{} = item -> append_media(item, media, size, limit)
    end
  end

  defp append_media(item, media, size, limit) do
    next_size = Media.Size.add(size, item)

    if next_size > limit do
      {:halt, {:error, {:resource_limit, :max_queue_bytes, limit}}}
    else
      {:cont, {:ok, [item | media], next_size}}
    end
  end
end
