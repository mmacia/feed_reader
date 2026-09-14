defmodule FeedReader.Recovery.Entities do
  @moduledoc """
  Recovers entity and markup irregularities in streamed XML.

  Some feeds contain raw ampersands or malformed entity references that Saxy
  rejects. This module preserves valid named and numeric entities, escapes
  invalid references, and leaves CDATA and comments untouched. Its scanner
  carries incomplete entities and markup delimiters between chunks so the
  result does not depend on the input chunk size.
  """

  @doc "Escapes invalid entity references while preserving CDATA and comments."
  def normalize(input) do
    Stream.transform(input, fn -> {:normal, <<>>} end, &normalize_chunk/2, &flush/1)
  end

  defp normalize_chunk(chunk, {mode, pending}) do
    {output, mode, pending} = scan(pending <> chunk, mode, [])
    emit(output, {mode, pending})
  end

  defp scan(data, :normal, output) do
    case next_markup(data) do
      :none ->
        case partial_prefix(data) do
          :none ->
            {append(output, data), :normal, <<>>}

          length ->
            split = byte_size(data) - length

            {append(output, binary_part(data, 0, split)), :normal,
             binary_part(data, split, length)}
        end

      {position, :cdata} ->
        {prefix, rest} = :erlang.split_binary(data, position)
        scan(binary_part(rest, 9, byte_size(rest) - 9), :cdata, ["<![CDATA[", prefix | output])

      {position, :comment} ->
        {prefix, rest} = :erlang.split_binary(data, position)
        scan(binary_part(rest, 4, byte_size(rest) - 4), :comment, ["<!--", prefix | output])

      {position, :entity} ->
        {prefix, rest} = :erlang.split_binary(data, position)
        normalize_reference(binary_part(rest, 1, byte_size(rest) - 1), [prefix | output])
    end
  end

  defp scan(data, :cdata, output), do: scan_delimited(data, output, "]]>", :cdata)
  defp scan(data, :comment, output), do: scan_delimited(data, output, "-->", :comment)

  defp scan_delimited(data, output, closing, mode) do
    case :binary.match(data, closing) do
      :nomatch ->
        keep = min(byte_size(data), 2)
        split = byte_size(data) - keep
        {append(output, binary_part(data, 0, split)), mode, binary_part(data, split, keep)}

      {position, length} ->
        {prefix, rest} = :erlang.split_binary(data, position + length)
        scan(rest, :normal, [prefix | output])
    end
  end

  defp next_markup(data) do
    [
      {:cdata, :binary.match(data, "<![CDATA[")},
      {:comment, :binary.match(data, "<!--")},
      {:entity, :binary.match(data, "&")}
    ]
    |> Enum.reduce(:none, &earliest/2)
  end

  defp partial_prefix(<<>>), do: :none

  defp partial_prefix(data) do
    max_length = min(byte_size(data), 8)

    Enum.find_value(max_length..1//-1, :none, fn length ->
      suffix = binary_part(data, byte_size(data) - length, length)

      if suffix in [binary_part("<![CDATA[", 0, length), binary_part("<!--", 0, min(length, 4))],
        do: length,
        else: false
    end)
  end

  defp earliest({_kind, :nomatch}, result), do: result
  defp earliest({kind, {position, _length}}, :none), do: {position, kind}

  defp earliest({kind, {position, _length}}, {current, _}) when position < current,
    do: {position, kind}

  defp earliest(_candidate, result), do: result

  defp normalize_reference(data, output) do
    case consume(data, "&") do
      {:complete, entity, rest} ->
        scan(rest, :normal, [if(valid?(entity), do: entity, else: escape(entity)) | output])

      {:invalid, entity, rest} ->
        scan(rest, :normal, [escape(entity) | output])

      :incomplete ->
        {output, :normal, "&" <> data}
    end
  end

  defp consume(<<>>, _entity), do: :incomplete
  defp consume(<<";", rest::binary>>, entity), do: {:complete, entity <> ";", rest}

  defp consume(<<char, rest::binary>>, entity) when char in [9, 10, 13, 32, 34, 38, 39, 60],
    do: {:invalid, entity, <<char, rest::binary>>}

  defp consume(<<char, rest::binary>>, entity), do: consume(rest, entity <> <<char>>)
  defp valid?(entity), do: Regex.match?(~r/^&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-f]+);$/i, entity)
  defp escape(entity), do: "&amp;" <> binary_part(entity, 1, byte_size(entity) - 1)
  defp append(output, <<>>), do: output
  defp append(output, chunk), do: [chunk | output]

  defp emit(output, state),
    do:
      if(output == [],
        do: {[], state},
        else: {[output |> Enum.reverse() |> IO.iodata_to_binary()], state}
      )

  defp flush({_mode, <<>>}), do: []
  defp flush({_mode, pending}), do: [pending]
end
