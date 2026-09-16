defmodule FeedReader.Recovery.Attributes do
  @moduledoc """
  Repairs malformed quotes in XML attributes.

  A small number of feeds place literal quotes inside a quoted attribute value.
  This module repairs those quotes only within one complete markup element, so
  valid quotes in neighboring elements cannot be rewritten accidentally.
  Incomplete elements are retained as state for the next input chunk.
  """

  @doc "Repairs literal quotes in streamed XML attributes."
  def normalize(input) do
    Stream.transform(
      input,
      fn -> <<>> end,
      fn chunk, pending ->
        {output, pending} = scan(pending <> chunk, [])
        {if(output == [], do: [], else: [IO.iodata_to_binary(Enum.reverse(output))]), pending}
      end,
      fn
        <<>> -> []
        pending -> [pending]
      end
    )
  end

  defp scan(<<>>, output), do: {output, <<>>}

  defp scan(data, output) do
    case :binary.match(data, "<") do
      :nomatch ->
        {[data | output], <<>>}

      {position, 1} when position > 0 ->
        {prefix, rest} = :erlang.split_binary(data, position)
        scan(rest, [prefix | output])

      {0, 1} ->
        case markup_end(data) do
          :incomplete -> {output, data}
          {markup, rest} -> scan(rest, [repair(markup) | output])
        end
    end
  end

  defp markup_end(<<"<![CDATA[", _rest::binary>> = data), do: special_end(data, "]]>")
  defp markup_end(<<"<!--", _rest::binary>> = data), do: special_end(data, "-->")

  defp markup_end(data) do
    case :binary.match(data, ">") do
      :nomatch -> :incomplete
      {position, 1} -> :erlang.split_binary(data, position + 1)
    end
  end

  defp special_end(data, closing) do
    case :binary.match(data, closing) do
      :nomatch -> :incomplete
      {position, length} -> :erlang.split_binary(data, position + length)
    end
  end

  defp repair(<<"<![CDATA[", _rest::binary>> = markup), do: markup
  defp repair(<<"<!--", _rest::binary>> = markup), do: markup
  defp repair(<<"<", rest::binary>>), do: "<" <> repair_tag(rest, nil, false, [])
  defp repair_tag(<<>>, _quote, _expect, output), do: IO.iodata_to_binary(Enum.reverse(output))

  defp repair_tag(<<char, rest::binary>>, nil, expect, output) when char in [32, 9, 10, 13],
    do: repair_tag(rest, nil, expect, [<<char>> | output])

  defp repair_tag(<<char, rest::binary>>, nil, true, output) when char in [34, 39],
    do: repair_tag(rest, {char, false}, false, [<<char>> | output])

  defp repair_tag(<<char, rest::binary>>, nil, _expect, output),
    do: repair_tag(rest, nil, char == ?=, [<<char>> | output])

  defp repair_tag(<<quote, rest::binary>>, {quote, has_content}, _expect, output) do
    cond do
      delimiter?(rest) ->
        repair_tag(rest, nil, false, [<<quote>> | output])

      empty_quote?(rest, quote, has_content) ->
        <<_quote, after_quote::binary>> = rest
        repair_tag(after_quote, nil, false, [<<quote>> | output])

      true ->
        repair_tag(rest, {quote, true}, false, ["&quot;" | output])
    end
  end

  defp repair_tag(<<char, rest::binary>>, {quote, _has_content}, _expect, output),
    do: repair_tag(rest, {quote, true}, false, [<<char>> | output])

  defp delimiter?(<<char, _rest::binary>>) when char in [32, 9, 10, 13, 47, 62, 63], do: true
  defp delimiter?(_rest), do: false
  defp empty_quote?(<<quote, rest::binary>>, quote, false), do: delimiter?(rest)
  defp empty_quote?(_rest, _quote, _has_content), do: false
end
