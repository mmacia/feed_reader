defmodule FeedReader.Recovery.Encoding do
  @moduledoc """
  Recovers character encoding mismatches in XML feeds.

  Some feeds declare ISO-8859-1 or Latin-1 while the XML parser pipeline is
  UTF-8 based. `transcode/2` converts those chunks without eagerly consuming
  the stream. `normalize_declaration/2` then rewrites the original declaration
  to UTF-8, including declarations split across input chunks.
  """

  def transcode(input, encoding) when encoding in [:utf8, :ascii], do: input

  def transcode(input, :latin1),
    do: Stream.map(input, &:unicode.characters_to_binary(&1, :latin1, :utf8))

  def normalize_declaration(input, :utf8), do: input

  def normalize_declaration(input, encoding) when encoding in [:latin1, :ascii] do
    Stream.transform(input, fn -> {:prolog, <<>>} end, &rewrite_chunk/2, &flush/1)
  end

  defp rewrite_chunk(chunk, {:prolog, prefix}) do
    data = prefix <> chunk

    case :binary.match(data, "?>") do
      {position, 2} ->
        {declaration, rest} = :erlang.split_binary(data, position + 2)
        {[rewrite(declaration) <> rest], :ready}

      :nomatch ->
        {[], {:prolog, data}}
    end
  end

  defp rewrite_chunk(chunk, :ready), do: {[chunk], :ready}

  defp rewrite(declaration),
    do:
      Regex.replace(~r/(encoding\s*=\s*["'])[^"']+(["'])/i, declaration, "\\1UTF-8\\2",
        global: false
      )

  defp flush({:prolog, prefix}), do: [prefix]
  defp flush(:ready), do: []
end
