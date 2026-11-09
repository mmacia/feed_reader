defmodule FeedReader.FormatDetector.RootTag do
  @moduledoc """
  Scans bounded XML prefixes for complete root start tags and quoted
  attributes, skipping prolog markup so detection can check root namespaces
  without parsing or consuming the full feed.
  """

  alias FeedReader.Recovery
  alias FeedReader.Recovery.{Attributes, Encoding, Entities, Prefix}
  alias FeedReader.XML.{Name, NamespaceScope}

  @type t :: %{name: String.t(), attributes: [{String.t(), String.t()}]}
  @type format :: :atom | :rdf | :unknown

  @doc "Classifies a complete Atom or RDF root using its namespace bindings."
  @spec classify(binary()) :: format()
  def classify(prefix) when is_binary(prefix) do
    case probe(prefix) do
      {:ok, %{name: name, attributes: attributes}} ->
        scope = NamespaceScope.new() |> NamespaceScope.enter(attributes)

        cond do
          Name.core_name?(name, scope, :atom, "feed") ->
            :atom

          Name.core_name?(name, scope, :rdf, "RDF") and
              (name != "RDF" or not is_nil(NamespaceScope.uri(scope, ""))) ->
            :rdf

          true ->
            :unknown
        end

      _result ->
        :unknown
    end
  end

  def classify(_prefix), do: :unknown

  @spec probe(binary()) :: {:ok, t()} | :incomplete | :invalid
  def probe(prefix) when is_binary(prefix) do
    case prepare_prefix(prefix) do
      {:ok, prepared} ->
        case locate(prepared) do
          {:ok, tag} -> parse_tag(tag)
          result -> result
        end

      result ->
        result
    end
  end

  def probe(_prefix), do: :invalid

  defp prepare_prefix(<<0xEF>>), do: :incomplete
  defp prepare_prefix(<<0xEF, 0xBB>>), do: :incomplete

  defp prepare_prefix(prefix) do
    prefix = [prefix] |> Prefix.normalize() |> Enum.join()

    case declaration(prefix) do
      {:ok, declaration} ->
        encoding = Recovery.declared_encoding("<?xml" <> declaration <> "?>")
        {:ok, [prefix] |> Encoding.transcode(encoding) |> recover_markup()}

      :none ->
        {:ok, recover_markup([prefix])}

      result ->
        result
    end
  end

  defp recover_markup(input),
    do: input |> Entities.normalize() |> Attributes.normalize() |> Enum.join()

  defp declaration(prefix) do
    case trim_space(prefix) do
      <<"<?xml", rest::binary>> ->
        declaration_content(rest)

      _other ->
        :none
    end
  end

  defp declaration_content(<<char, rest::binary>>) when char in [9, 10, 13, 32] do
    case :binary.match(rest, "?>") do
      {offset, 2} -> {:ok, <<char>> <> binary_part(rest, 0, offset)}
      :nomatch -> :incomplete
    end
  end

  defp declaration_content(<<>>), do: :incomplete
  defp declaration_content(_rest), do: :none

  defp locate(<<char, rest::binary>>) when char in [32, 9, 10, 13], do: locate(rest)
  defp locate(<<"<!--", rest::binary>>), do: skip_delimited(rest, "-->")
  defp locate(<<"<?", rest::binary>>), do: skip_delimited(rest, "?>")
  defp locate(<<"<![CDATA[", rest::binary>>), do: skip_delimited(rest, "]]>")

  defp locate(<<"<!", rest::binary>>) do
    case scan_tag(rest, nil, []) do
      {:ok, _declaration, trailing} -> locate(trailing)
      :incomplete -> :incomplete
    end
  end

  defp locate(<<"<", rest::binary>>) do
    case scan_tag(rest, nil, []) do
      {:ok, tag, _trailing} -> {:ok, tag}
      :incomplete -> :incomplete
    end
  end

  defp locate(<<>>), do: :incomplete
  defp locate(_prefix), do: :invalid

  defp skip_delimited(rest, delimiter) do
    case :binary.match(rest, delimiter) do
      {offset, length} ->
        locate(binary_part(rest, offset + length, byte_size(rest) - offset - length))

      :nomatch ->
        :incomplete
    end
  end

  defp scan_tag(<<>>, _quote, _reversed), do: :incomplete

  defp scan_tag(<<char, rest::binary>>, quote, reversed) when not is_nil(quote) do
    if char == quote,
      do: scan_tag(rest, nil, [char | reversed]),
      else: scan_tag(rest, quote, [char | reversed])
  end

  defp scan_tag(<<char, rest::binary>>, nil, reversed) when char in [?", ?'] do
    scan_tag(rest, char, [char | reversed])
  end

  defp scan_tag(<<?>, rest::binary>>, nil, reversed),
    do: {:ok, reversed |> Enum.reverse() |> :erlang.list_to_binary() |> Kernel.<>(">"), rest}

  defp scan_tag(<<char, rest::binary>>, nil, reversed), do: scan_tag(rest, nil, [char | reversed])

  defp parse_tag(tag) do
    body = binary_part(tag, 0, byte_size(tag) - 1)

    with {:ok, name, rest} <- read_name(body),
         {:ok, attributes} <- read_attributes(rest, []) do
      {:ok, %{name: name, attributes: attributes}}
    else
      _result -> :invalid
    end
  end

  defp read_name(binary) do
    {name, rest} = take_while(binary, [], &(&1 not in [32, 9, 10, 13, ?/, ?=]))
    if name == "", do: :invalid, else: {:ok, name, rest}
  end

  defp read_attributes(rest, attributes) do
    case trim_space(rest) do
      "" -> {:ok, Enum.reverse(attributes)}
      "/" -> {:ok, Enum.reverse(attributes)}
      rest -> read_attribute(rest, attributes)
    end
  end

  defp read_attribute(rest, attributes) do
    with {:ok, name, rest} <- read_attribute_name(rest),
         "=" <> rest <- trim_space(rest),
         {:ok, value, rest} <- read_quoted(trim_space(rest)),
         {:ok, value} <- decode_references(value) do
      read_attributes(rest, [{name, value} | attributes])
    else
      _result -> :invalid
    end
  end

  defp read_attribute_name(binary) do
    {name, rest} = take_while(binary, [], &(&1 not in [32, 9, 10, 13, ?=, ?/]))
    if name == "", do: :invalid, else: {:ok, name, rest}
  end

  defp read_quoted(<<quote, rest::binary>>) when quote in [?", ?'] do
    # scan_tag only returns complete tags, so the closing quote is guaranteed.
    {offset, 1} = :binary.match(rest, <<quote>>)
    value = binary_part(rest, 0, offset)
    trailing = binary_part(rest, offset + 1, byte_size(rest) - offset - 1)
    {:ok, value, trailing}
  end

  defp read_quoted(_rest), do: :invalid

  defp decode_references(value), do: decode_references(value, [])

  defp decode_references(<<>>, reversed),
    do: {:ok, reversed |> Enum.reverse() |> IO.iodata_to_binary()}

  defp decode_references(<<"&", rest::binary>>, reversed) do
    case :binary.match(rest, ";") do
      {offset, 1} ->
        reference = binary_part(rest, 0, offset)
        trailing = binary_part(rest, offset + 1, byte_size(rest) - offset - 1)

        case decode_reference(reference) do
          {:ok, decoded} -> decode_references(trailing, [decoded | reversed])
          :error -> :invalid
        end

      :nomatch ->
        :invalid
    end
  end

  defp decode_references(<<char, rest::binary>>, reversed),
    do: decode_references(rest, [<<char>> | reversed])

  defp decode_reference("amp"), do: {:ok, "&"}
  defp decode_reference("lt"), do: {:ok, "<"}
  defp decode_reference("gt"), do: {:ok, ">"}
  defp decode_reference("apos"), do: {:ok, "'"}
  defp decode_reference("quot"), do: {:ok, "\""}

  defp decode_reference("#x" <> digits), do: decode_codepoint(digits, 16)
  defp decode_reference("#X" <> digits), do: decode_codepoint(digits, 16)
  defp decode_reference("#" <> digits), do: decode_codepoint(digits, 10)
  defp decode_reference(_reference), do: :error

  defp decode_codepoint(digits, base) do
    case Integer.parse(digits, base) do
      {codepoint, ""} when codepoint in [9, 10, 13] -> {:ok, <<codepoint::utf8>>}
      {codepoint, ""} when codepoint in 0x20..0xD7FF -> {:ok, <<codepoint::utf8>>}
      {codepoint, ""} when codepoint in 0xE000..0xFFFD -> {:ok, <<codepoint::utf8>>}
      {codepoint, ""} when codepoint in 0x10000..0x10FFFF -> {:ok, <<codepoint::utf8>>}
      _invalid -> :error
    end
  end

  defp take_while(<<char, rest::binary>>, reversed, predicate) do
    if predicate.(char),
      do: take_while(rest, [char | reversed], predicate),
      else: {reversed |> Enum.reverse() |> :erlang.list_to_binary(), <<char, rest::binary>>}
  end

  defp take_while(<<>>, reversed, _predicate),
    do: {reversed |> Enum.reverse() |> :erlang.list_to_binary(), ""}

  defp trim_space(<<char, rest::binary>>) when char in [32, 9, 10, 13], do: trim_space(rest)
  defp trim_space(binary), do: binary
end
