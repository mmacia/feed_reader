defmodule FeedReader.Recovery.Prefix do
  @moduledoc """
  Recovers the beginning of an XML document before SAX parsing.

  Feeds commonly contain a UTF-8 BOM or whitespace before the XML declaration,
  while Saxy expects the document to begin at the XML prolog or root element.
  This module removes those prefixes incrementally and retains incomplete BOM
  bytes across chunks, so it is safe for arbitrarily small stream chunks.
  """

  def normalize(input) do
    Stream.transform(input, fn -> {:leading, <<>>} end, &normalize_chunk/2, &flush/1)
  end

  defp normalize_chunk(chunk, {:leading, prefix}) do
    data = prefix <> chunk

    if bom_prefix?(data) do
      {[], {:leading, data}}
    else
      output =
        if starts_with_bom?(data), do: binary_part(data, 3, byte_size(data) - 3), else: data

      output = trim_whitespace(output)
      if output == <<>>, do: {[], {:leading, <<>>}}, else: {[output], :ready}
    end
  end

  defp normalize_chunk(chunk, :ready), do: {[chunk], :ready}

  defp bom_prefix?(data) when byte_size(data) < 3,
    do: data == binary_part(<<0xEF, 0xBB, 0xBF>>, 0, byte_size(data))

  defp bom_prefix?(_data), do: false
  defp starts_with_bom?(<<0xEF, 0xBB, 0xBF, _rest::binary>>), do: true
  defp starts_with_bom?(_data), do: false

  defp trim_whitespace(<<char, rest::binary>>) when char in [9, 10, 13, 32],
    do: trim_whitespace(rest)

  defp trim_whitespace(data), do: data
  defp flush({:leading, <<>>}), do: []
  defp flush({:leading, prefix}), do: [prefix]
  defp flush(:ready), do: []
end
