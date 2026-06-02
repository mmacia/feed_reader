defmodule FeedReader.Downloader do
  @moduledoc """
  Streams remote response bodies into owned temporary files while computing the
  decoded MD5 checksum. Gzip and raw deflate are decoded incrementally; stacked
  and unknown content encodings are rejected. See `download/2` for its options
  and resource budgets.
  """

  alias FeedReader.{Fetch, Transport}

  @defaults [
    max_compressed_bytes: 52_428_800,
    max_decoded_bytes: 52_428_800,
    max_temp_bytes: 52_428_800,
    max_expansion_ratio: 100
  ]

  @doc """
  Downloads, decodes, checksums, and owns a temporary response file.

  ## Options

  - `:http_client` — module implementing `FeedReader.Transport`; defaults to
    `FeedReader.ReqTransport`.
  - `:http_options` — Req request options. The default transport streams raw
    response chunks, disables automatic decompression, and limits redirects to
    its configured limit. A supplied `:headers` list replaces its default
    headers.
  - `:previous_etag` — binary ETag sent verbatim as `If-None-Match`. A 304
    response returns `{:ok, :not_modified}` without creating a temporary file.
  - `:http_retry_attempts` — non-negative retry count after the initial request;
    defaults to the `FeedReader.ReqTransport` setting. Invalid values use the
    default.
  - `:retry_delay` — non-negative delay in milliseconds or an arity-one retry
    delay function; defaults to the `FeedReader.ReqTransport` setting. Invalid
    values use the default.
  - `:previous_checksum` — checksum of the previous decoded body. An exact match
    returns `{:ok, :not_changed}` and removes the temporary file.
  - `:max_compressed_bytes` — maximum cumulative raw response size; defaults to
    `#{@defaults[:max_compressed_bytes]}` bytes.
  - `:max_decoded_bytes` — maximum cumulative decompressed body size; defaults to
    `#{@defaults[:max_decoded_bytes]}` bytes.
  - `:max_temp_bytes` — maximum bytes written to the owned temporary file;
    defaults to `#{@defaults[:max_temp_bytes]}` bytes.
  - `:max_expansion_ratio` — maximum decoded-to-compressed byte ratio; defaults
    to `#{@defaults[:max_expansion_ratio]}`.

  Invalid resource-limit values use their defaults. Limits are checked as body
  chunks are processed. Successful downloads return the owned path and a
  `FeedReader.Fetch`; callers must pass the download result to `close/1` when
  finished. Errors remove any temporary file created for the request.
  """
  @spec download(String.t(), keyword()) ::
          {:ok, %{path: Path.t(), fetch: Fetch.t()}}
          | {:ok, :not_changed | :not_modified}
          | {:error, term()}
  def download(url, opts) when is_binary(url) do
    with {:ok, response} <- Transport.request(url, opts) do
      case response.status do
        304 ->
          {:ok, :not_modified}

        status when status in 200..299 ->
          download_body(url, response, opts)

        status ->
          {:error, {:http_status, status}}
      end
    end
  end

  def download(_url, _opts), do: {:error, :invalid_url}

  @doc "Removes a downloaded temporary file; safe to call more than once."
  @spec close(%{path: Path.t()}) :: :ok
  def close(%{path: path}) do
    _ = File.rm(path)
    :ok
  end

  defp download_body(url, response, opts) do
    with {:ok, encoding} <- content_encoding(response.headers),
         {:ok, path, file} <- open_temp_file() do
      result =
        try do
          consume_body(response.body, file, encoding, opts)
        after
          File.close(file)
        end

      finish_download(result, path, url, response, opts)
    end
  end

  defp finish_download({:ok, checksum}, path, url, response, opts) do
    if checksum == Keyword.get(opts, :previous_checksum) do
      File.rm(path)
      {:ok, :not_changed}
    else
      fetch = %Fetch{
        etag: header(response.headers, "etag"),
        checksum: checksum,
        final_url: response.final_url || url,
        status: response.status
      }

      {:ok, %{path: path, fetch: fetch}}
    end
  end

  defp finish_download({:error, _} = error, path, _url, _response, _opts) do
    File.rm(path)
    error
  end

  defp consume_body(body, file, encoding, opts) do
    initial = %{compressed: 0, decoded: 0, hash: :crypto.hash_init(:md5)}

    try do
      decoder = start_decoder(encoding)

      try do
        body
        |> Enum.reduce_while({:ok, initial}, &consume_chunk(&1, &2, decoder, file, opts))
        |> case do
          {:ok, state} -> {:ok, Base.encode16(:crypto.hash_final(state.hash), case: :lower)}
          error -> error
        end
      after
        if decoder, do: :zlib.close(decoder)
      end
    rescue
      error -> {:error, {:download_failed, error}}
    end
  end

  defp consume_chunk(chunk, {:ok, state}, decoder, file, opts) when is_binary(chunk) do
    with {:ok, state} <- count_compressed(state, byte_size(chunk), opts),
         {:ok, outputs} <- decode_chunk(decoder, chunk),
         {:ok, state} <- write_outputs(outputs, file, state, opts) do
      {:cont, {:ok, state}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp consume_chunk(_chunk, _state, _decoder, _file, _opts),
    do: {:halt, {:error, :invalid_chunk}}

  defp write_outputs(outputs, file, state, opts) do
    Enum.reduce_while(outputs, {:ok, state}, fn output, {:ok, state} ->
      decoded = state.decoded + byte_size(output)
      decoded_limit = limit(opts, :max_decoded_bytes)
      temp_limit = limit(opts, :max_temp_bytes)
      ratio = limit(opts, :max_expansion_ratio)

      cond do
        decoded > decoded_limit ->
          {:halt, resource_error(:max_decoded_bytes, decoded_limit)}

        decoded > temp_limit ->
          {:halt, resource_error(:max_temp_bytes, temp_limit)}

        decoded > max(state.compressed, 1) * ratio ->
          {:halt, resource_error(:max_expansion_ratio, ratio)}

        true ->
          :ok = IO.binwrite(file, output)
          state = %{state | decoded: decoded, hash: :crypto.hash_update(state.hash, output)}
          {:cont, {:ok, state}}
      end
    end)
  end

  defp count_compressed(state, bytes, opts) do
    total = state.compressed + bytes
    max_bytes = limit(opts, :max_compressed_bytes)

    if total > max_bytes,
      do: resource_error(:max_compressed_bytes, max_bytes),
      else: {:ok, %{state | compressed: total}}
  end

  defp decode_chunk(nil, chunk), do: {:ok, [chunk]}

  defp decode_chunk(decoder, chunk) do
    {:ok, inflate(decoder, chunk)}
  rescue
    _error -> {:error, :invalid_compressed_body}
  end

  defp inflate(decoder, input) do
    case :zlib.safeInflate(decoder, input) do
      {status, output} when status in [:continue, :finished] ->
        output = if output == [], do: [], else: [IO.iodata_to_binary(output)]
        if status == :continue, do: output ++ inflate(decoder, []), else: output
    end
  end

  defp start_decoder(nil), do: nil
  defp start_decoder(:gzip), do: decoder(31)
  defp start_decoder(:deflate), do: decoder(-15)

  defp decoder(window_bits) do
    zlib = :zlib.open()
    :ok = :zlib.inflateInit(zlib, window_bits)
    zlib
  end

  defp content_encoding(headers) do
    case header(headers, "content-encoding") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        decode_encoding(String.downcase(String.trim(value)))
    end
  end

  defp decode_encoding("identity"), do: {:ok, nil}
  defp decode_encoding(encoding) when encoding in ["gzip", "x-gzip"], do: {:ok, :gzip}
  defp decode_encoding("deflate"), do: {:ok, :deflate}
  defp decode_encoding(_encoding), do: {:error, :unsupported_content_encoding}

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp open_temp_file do
    path =
      Path.join(
        System.tmp_dir!(),
        "feed_reader-download-#{System.unique_integer([:positive])}.xml"
      )

    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} -> {:ok, path, file}
      error -> error
    end
  end

  defp limit(opts, key), do: valid_limit(Keyword.get(opts, key, @defaults[key]), @defaults[key])
  defp valid_limit(value, _default) when is_integer(value) and value >= 0, do: value
  defp valid_limit(_invalid, default), do: default

  defp resource_error(key, limit), do: {:error, {:resource_limit, key, limit}}
end
