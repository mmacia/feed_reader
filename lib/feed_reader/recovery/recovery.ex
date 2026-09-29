defmodule FeedReader.Recovery do
  alias FeedReader.Recovery.{Attributes, Encoding, Entities, Prefix}

  @moduledoc """
  Public facade for streaming XML recovery.

  It detects declared encodings and applies prefix, encoding, entity, and
  malformed-attribute recovery in that order. Each stage preserves streaming
  behavior and carries incomplete markup across chunk boundaries.
  """

  @doc "Returns the encoding declared by an XML prefix, defaulting to UTF-8."
  @spec declared_encoding(binary()) :: :utf8 | :latin1 | :ascii
  def declared_encoding(prefix) do
    case Regex.run(~r/<\?xml\b[^>]*\bencoding\s*=\s*["']([^"']+)["']/is, prefix,
           capture: :all_but_first
         ) do
      [encoding] -> normalize_encoding(encoding)
      _none -> :utf8
    end
  end

  @doc "Normalizes an enumerable of XML chunks without eagerly consuming it."
  @spec normalize(Enumerable.t(), :utf8 | :latin1 | :ascii) :: Enumerable.t()
  def normalize(input, encoding) do
    input
    |> Prefix.normalize()
    |> Encoding.transcode(encoding)
    |> Encoding.normalize_declaration(encoding)
    |> Entities.normalize()
    |> Attributes.normalize()
  end

  defp normalize_encoding(encoding) do
    case String.downcase(encoding) do
      value when value in ["iso-8859-1", "latin1", "latin-1"] -> :latin1
      "us-ascii" -> :ascii
      _utf8 -> :utf8
    end
  end
end
