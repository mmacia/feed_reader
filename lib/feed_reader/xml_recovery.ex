defmodule FeedReader.XMLRecovery do
  @moduledoc """
  Streaming recovery and normalization for imperfect XML feeds.

  The recovery pipeline applies these compatibility repairs before the XML
  parser receives the input:

    * Detects XML declarations that use ISO-8859-1, Latin-1, or Latin1.
    * Removes a UTF-8 byte-order mark and whitespace before the XML document.
    * Transcodes Latin-1 input to UTF-8.
    * Rewrites a Latin-1 XML declaration to `encoding="UTF-8"` after transcoding.
    * Preserves valid XML entities and escapes invalid or raw ampersand
      references.
    * Leaves CDATA sections and comments untouched while normalizing entities.
    * Repairs literal quotes inside malformed quoted attributes, without
      allowing a repair to cross XML element boundaries.
    * Handles entities, markup, CDATA, comments, and attributes split across
      arbitrary input chunks.

  Recovery is intentionally compatibility-oriented. It does not attempt to
  make arbitrary malformed XML valid; it only repairs the feed irregularities
  covered by the streaming normalizers above.
  """

  @doc "Returns the encoding declared by an XML prefix, defaulting to UTF-8."
  @spec declared_encoding(binary()) :: :utf8 | :latin1
  def declared_encoding(prefix) do
    case Regex.run(~r/<\?xml\b[^>]*\bencoding\s*=\s*["']([^"']+)["']/is, prefix,
           capture: :all_but_first
         ) do
      [encoding] -> normalize_encoding(encoding)
      _none -> :utf8
    end
  end

  @doc "Normalizes an enumerable of XML chunks without eagerly consuming it."
  @spec normalize(Enumerable.t(), :utf8 | :latin1) :: Enumerable.t()
  def normalize(input, encoding) do
    input
    |> normalize_xml_prefix()
    |> transcode_input(encoding)
    |> normalize_encoding_declaration(encoding)
    |> normalize_entities()
    |> normalize_attribute_quotes()
  end

  defp normalize_encoding(encoding) do
    case String.downcase(encoding) do
      value when value in ["iso-8859-1", "latin1", "latin-1"] -> :latin1
      _utf8 -> :utf8
    end
  end

  defp normalize_xml_prefix(input) do
    Stream.transform(
      input,
      fn -> {:leading, <<>>} end,
      &normalize_prefix_chunk/2,
      &flush_prefix/1
    )
  end

  defp normalize_prefix_chunk(chunk, {:leading, prefix}) do
    data = prefix <> chunk

    if bom_prefix?(data) do
      {[], {:leading, data}}
    else
      output =
        if starts_with_bom?(data), do: binary_part(data, 3, byte_size(data) - 3), else: data

      output = trim_leading_xml_whitespace(output)

      if output == <<>>, do: {[], {:leading, <<>>}}, else: {[output], :ready}
    end
  end

  defp normalize_prefix_chunk(chunk, :ready), do: {[chunk], :ready}

  defp bom_prefix?(data) when byte_size(data) < 3,
    do: data == binary_part(<<0xEF, 0xBB, 0xBF>>, 0, byte_size(data))

  defp bom_prefix?(_data), do: false
  defp starts_with_bom?(<<0xEF, 0xBB, 0xBF, _rest::binary>>), do: true
  defp starts_with_bom?(_data), do: false

  defp trim_leading_xml_whitespace(<<char, rest::binary>>) when char in [9, 10, 13, 32],
    do: trim_leading_xml_whitespace(rest)

  defp trim_leading_xml_whitespace(data), do: data
  defp flush_prefix({:leading, <<>>}), do: []
  defp flush_prefix({:leading, prefix}), do: [prefix]
  defp flush_prefix(:ready), do: []

  defp transcode_input(input, :utf8), do: input

  defp transcode_input(input, :latin1),
    do: Stream.map(input, fn chunk -> :unicode.characters_to_binary(chunk, :latin1, :utf8) end)

  defp normalize_encoding_declaration(input, :utf8), do: input

  defp normalize_encoding_declaration(input, :latin1) do
    Stream.transform(
      input,
      fn -> {:prolog, <<>>} end,
      &rewrite_declaration_chunk/2,
      &flush_declaration/1
    )
  end

  defp rewrite_declaration_chunk(chunk, {:prolog, prefix}) do
    data = prefix <> chunk

    case :binary.match(data, "?>") do
      {position, 2} ->
        {declaration, rest} = :erlang.split_binary(data, position + 2)
        {[rewrite_declaration(declaration) <> rest], :ready}

      :nomatch ->
        {[], {:prolog, data}}
    end
  end

  defp rewrite_declaration_chunk(chunk, :ready), do: {[chunk], :ready}

  defp rewrite_declaration(declaration),
    do:
      Regex.replace(~r/(encoding\s*=\s*["'])[^"']+(["'])/i, declaration, "\\1UTF-8\\2",
        global: false
      )

  defp flush_declaration({:prolog, prefix}), do: [prefix]
  defp flush_declaration(:ready), do: []

  defp normalize_entities(input) do
    Stream.transform(
      input,
      fn -> {:normal, <<>>} end,
      &normalize_entity_chunk/2,
      &flush_entities/1
    )
  end

  defp normalize_entity_chunk(chunk, {mode, pending}) do
    {output, mode, pending} = scan_entities(pending <> chunk, mode, [])
    emit_entity_chunk(output, {mode, pending})
  end

  defp scan_entities(data, :normal, output) do
    case next_markup(data) do
      :none ->
        case partial_markup_prefix(data) do
          :none ->
            {append_output(output, data), :normal, <<>>}

          length ->
            split = byte_size(data) - length

            {append_output(output, binary_part(data, 0, split)), :normal,
             binary_part(data, split, length)}
        end

      {position, :cdata} ->
        {prefix, rest} = :erlang.split_binary(data, position)

        scan_entities(binary_part(rest, 9, byte_size(rest) - 9), :cdata, [
          "<![CDATA[",
          prefix | output
        ])

      {position, :comment} ->
        {prefix, rest} = :erlang.split_binary(data, position)

        scan_entities(binary_part(rest, 4, byte_size(rest) - 4), :comment, [
          "<!--",
          prefix | output
        ])

      {position, :entity} ->
        {prefix, rest} = :erlang.split_binary(data, position)
        normalize_entity_reference(binary_part(rest, 1, byte_size(rest) - 1), [prefix | output])
    end
  end

  defp scan_entities(data, :cdata, output) do
    case :binary.match(data, "]]>") do
      :nomatch ->
        keep = min(byte_size(data), 2)
        split = byte_size(data) - keep

        {append_output(output, binary_part(data, 0, split)), :cdata,
         binary_part(data, split, keep)}

      {position, 3} ->
        {prefix, rest} = :erlang.split_binary(data, position + 3)
        scan_entities(rest, :normal, [prefix | output])
    end
  end

  defp scan_entities(data, :comment, output) do
    case :binary.match(data, "-->") do
      :nomatch ->
        keep = min(byte_size(data), 2)
        split = byte_size(data) - keep

        {append_output(output, binary_part(data, 0, split)), :comment,
         binary_part(data, split, keep)}

      {position, 3} ->
        {prefix, rest} = :erlang.split_binary(data, position + 3)
        scan_entities(rest, :normal, [prefix | output])
    end
  end

  defp next_markup(data) do
    [
      {:cdata, :binary.match(data, "<![CDATA[")},
      {:comment, :binary.match(data, "<!--")},
      {:entity, :binary.match(data, "&")}
    ]
    |> Enum.reduce(:none, &earliest_markup/2)
  end

  defp partial_markup_prefix(<<>>), do: :none

  defp partial_markup_prefix(data) do
    max_length = min(byte_size(data), 8)

    Enum.find_value(max_length..1//-1, :none, fn length ->
      suffix = binary_part(data, byte_size(data) - length, length)

      if suffix in [binary_part("<![CDATA[", 0, length), binary_part("<!--", 0, min(length, 4))],
        do: length,
        else: false
    end)
  end

  defp earliest_markup({_kind, :nomatch}, result), do: result
  defp earliest_markup({kind, {position, _length}}, :none), do: {position, kind}

  defp earliest_markup({kind, {position, _length}}, {current, _current_kind})
       when position < current, do: {position, kind}

  defp earliest_markup(_candidate, result), do: result

  defp normalize_entity_reference(data, output) do
    case consume_entity(data, "&") do
      {:complete, entity, rest} ->
        entity = if valid_entity?(entity), do: entity, else: escape_entity(entity)
        scan_entities(rest, :normal, [entity | output])

      {:invalid, entity, rest} ->
        scan_entities(rest, :normal, [escape_entity(entity) | output])

      :incomplete ->
        {output, :normal, "&" <> data}
    end
  end

  defp consume_entity(<<>>, _entity), do: :incomplete
  defp consume_entity(<<";", rest::binary>>, entity), do: {:complete, entity <> ";", rest}

  defp consume_entity(<<char, rest::binary>>, entity)
       when char in [9, 10, 13, 32, 34, 38, 39, 60],
       do: {:invalid, entity, <<char, rest::binary>>}

  defp consume_entity(<<char, rest::binary>>, entity),
    do: consume_entity(rest, entity <> <<char>>)

  defp valid_entity?(entity),
    do: Regex.match?(~r/^&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-f]+);$/i, entity)

  defp escape_entity(entity), do: "&amp;" <> binary_part(entity, 1, byte_size(entity) - 1)
  defp append_output(output, <<>>), do: output
  defp append_output(output, chunk), do: [chunk | output]

  defp emit_entity_chunk(output, state) do
    output = output |> Enum.reverse() |> IO.iodata_to_binary()
    if output == <<>>, do: {[], state}, else: {[output], state}
  end

  defp flush_entities({_mode, <<>>}), do: []
  defp flush_entities({_mode, pending}), do: [pending]

  defp normalize_attribute_quotes(input) do
    Stream.transform(
      input,
      fn -> <<>> end,
      fn chunk, pending ->
        {output, pending} = scan_attribute_markup(pending <> chunk, [])
        {if(output == [], do: [], else: [IO.iodata_to_binary(Enum.reverse(output))]), pending}
      end,
      fn
        <<>> -> []
        pending -> [pending]
      end
    )
  end

  defp scan_attribute_markup(<<>>, output), do: {output, <<>>}

  defp scan_attribute_markup(data, output) do
    case :binary.match(data, "<") do
      :nomatch ->
        {[data | output], <<>>}

      {position, 1} when position > 0 ->
        {prefix, rest} = :erlang.split_binary(data, position)
        scan_attribute_markup(rest, [prefix | output])

      {0, 1} ->
        case markup_end(data) do
          :incomplete -> {output, data}
          {markup, rest} -> scan_attribute_markup(rest, [repair_markup_quotes(markup) | output])
        end
    end
  end

  defp markup_end(<<"<![CDATA[", _rest::binary>> = data), do: special_markup_end(data, "]]>")
  defp markup_end(<<"<!--", _rest::binary>> = data), do: special_markup_end(data, "-->")

  defp markup_end(data) do
    case :binary.match(data, ">") do
      :nomatch -> :incomplete
      {position, 1} -> :erlang.split_binary(data, position + 1)
    end
  end

  defp special_markup_end(data, closing) do
    case :binary.match(data, closing) do
      :nomatch -> :incomplete
      {position, length} -> :erlang.split_binary(data, position + length)
    end
  end

  defp repair_markup_quotes(<<"<![CDATA[", _rest::binary>> = markup), do: markup
  defp repair_markup_quotes(<<"<!--", _rest::binary>> = markup), do: markup

  defp repair_markup_quotes(<<"<", rest::binary>>),
    do: "<" <> repair_tag_quotes(rest, nil, false, [])

  defp repair_tag_quotes(<<>>, _quote, _expect, output),
    do: IO.iodata_to_binary(Enum.reverse(output))

  defp repair_tag_quotes(<<char, rest::binary>>, nil, expect, output)
       when char in [32, 9, 10, 13], do: repair_tag_quotes(rest, nil, expect, [<<char>> | output])

  defp repair_tag_quotes(<<char, rest::binary>>, nil, true, output) when char in [34, 39],
    do: repair_tag_quotes(rest, {char, false}, false, [<<char>> | output])

  defp repair_tag_quotes(<<char, rest::binary>>, nil, _expect, output),
    do: repair_tag_quotes(rest, nil, char == ?=, [<<char>> | output])

  defp repair_tag_quotes(<<quote, rest::binary>>, {quote, has_content}, _expect, output) do
    cond do
      delimiter?(rest) ->
        repair_tag_quotes(rest, nil, false, [<<quote>> | output])

      empty_attribute_quote?(rest, quote, has_content) ->
        <<_quote, after_quote::binary>> = rest
        repair_tag_quotes(after_quote, nil, false, [<<quote>> | output])

      true ->
        repair_tag_quotes(rest, {quote, true}, false, ["&quot;" | output])
    end
  end

  defp repair_tag_quotes(<<char, rest::binary>>, {quote, _has_content}, _expect, output),
    do: repair_tag_quotes(rest, {quote, true}, false, [<<char>> | output])

  defp delimiter?(<<char, _rest::binary>>) when char in [32, 9, 10, 13, 47, 62, 63], do: true
  defp delimiter?(_rest), do: false
  defp empty_attribute_quote?(<<quote, rest::binary>>, quote, false), do: delimiter?(rest)
  defp empty_attribute_quote?(_rest, _quote, _has_content), do: false
end
