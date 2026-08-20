defmodule FeedReader.Collector do
  @moduledoc """
  Bounded collectors for local feed parsing.

  The collector consumes the event stream produced by `FeedReader.Parser` and
  returns a `FeedReader.ParseResult`. Callers must provide a positive integer
  `:max_items`; accepted items beyond that limit produce an error instead of a
  partial result. The parser stops after the feed's root element, so content
  appended after a complete feed is not parsed.

  Binary and chunk-enumerable inputs are written incrementally to a temporary
  file before parsing. The temporary file is owned and removed by the collector;
  caller-owned files passed to `collect/2` are never removed.
  """

  alias FeedReader.ParseResult

  @doc """
  Collects events from a caller-owned local feed file.

  The `:item_filter` option may contain a one-argument function. It is applied
  before items are counted and retained. The result contains normalized feed
  metadata and the accepted items, or an error without partial data.
  """
  @spec collect(Path.t(), keyword()) :: {:ok, ParseResult.t()} | {:error, term()}
  def collect(path, opts) do
    with {:ok, max_items} <- max_items(opts),
         {:ok, session} <- FeedReader.Parser.stream_file(path, opts) do
      collect_events(session.events, max_items, opts)
    end
  end

  @doc "Collects a session and releases its owned source on every outcome."
  @spec collect_session(FeedReader.Session.t(), keyword()) ::
          {:ok, ParseResult.t()} | {:error, term()}
  def collect_session(session, opts) do
    collect_session_events(session, opts)
  after
    FeedReader.close(session)
  end

  defp collect_session_events(session, opts) do
    with {:ok, max_items} <- max_items(opts) do
      collect_events(session.events, max_items, opts)
    end
  end

  @doc """
  Collects XML chunks from an enumerable.

  Chunks must be binaries. They are written incrementally to a library-owned
  temporary file, which is removed on success, parser failure, or write
  failure. Collection options have the same meaning as `collect/2`.
  """
  @spec parse_stream(Enumerable.t(), keyword()) ::
          {:ok, ParseResult.t()} | {:error, term()}
  def parse_stream(chunks, opts) do
    with {:ok, _max_items} <- max_items(opts),
         {:ok, path} <- temporary_path() do
      write_and_collect(path, chunks, opts)
    end
  end

  @spec collect_events(Enumerable.t(), pos_integer(), keyword()) ::
          {:ok, ParseResult.t()} | {:error, term()}
  defp collect_events(events, max_items, opts) do
    filter = Keyword.get(opts, :item_filter, fn _item -> true end)

    if is_function(filter, 1) do
      events
      |> Enum.reduce_while({nil, [], 0, nil}, &collect_event(&1, &2, max_items, filter))
      |> collection_result()
    else
      {:error, {:invalid_option, :item_filter}}
    end
  end

  @doc """
  Validates the required collection limit.

  Returns `{:ok, max_items}` for a positive integer and
  `{:error, {:invalid_option, :max_items}}` for all other values.
  """
  @spec max_items(keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def max_items(opts) do
    case Keyword.get(opts, :max_items) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, {:invalid_option, :max_items}}
    end
  end

  defp collect_event({:feed, feed}, {nil, items, count, error}, _max, _filter),
    do: {:cont, {feed, items, count, error}}

  defp collect_event({:feed, _feed}, state, _max, _filter), do: {:cont, state}

  defp collect_event({:item, item}, {feed, items, count, error}, max, filter) do
    if filter.(item) do
      state =
        if count < max do
          {feed, [item | items], count + 1, error}
        else
          {feed, items, count + 1, error || {:max_items_exceeded, max}}
        end

      {:cont, state}
    else
      {:cont, {feed, items, count, error}}
    end
  end

  defp collect_event({:error, reason}, {feed, items, count, _error}, _max, _filter),
    do: {:halt, {feed, items, count, reason}}

  defp collect_event(_event, state, _max, _filter), do: {:cont, state}

  defp collection_result({_feed, _items, _count, error}) when not is_nil(error),
    do: {:error, error}

  defp collection_result({nil, _items, _count, _error}), do: {:error, :feed_metadata_missing}

  defp collection_result({feed, items, _count, nil}),
    do: {:ok, %ParseResult{feed: feed, items: Enum.reverse(items)}}

  defp temporary_path do
    path =
      Path.join(System.tmp_dir!(), "feed_reader-parse-#{System.unique_integer([:positive])}.xml")

    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        File.close(file)
        {:ok, path}

      {:error, :eexist} ->
        temporary_path()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_and_collect(path, chunks, opts) do
    case File.open(path, [:write, :binary]) do
      {:ok, file} ->
        result = write_chunks(file, chunks)
        File.close(file)

        case result do
          :ok -> collect(path, opts)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:stream_write_failed, error}}
  after
    File.rm(path)
  end

  defp write_chunks(file, chunks) do
    Enum.reduce_while(chunks, :ok, fn
      chunk, :ok when is_binary(chunk) ->
        IO.binwrite(file, chunk)
        {:cont, :ok}

      _chunk, :ok ->
        {:halt, {:error, :invalid_chunk}}
    end)
  end
end
