defmodule FeedReader.Formats.RDF do
  @moduledoc false

  def matches_prefix?(prefix), do: Regex.match?(~r/<rdf:rdf\b/is, prefix)

  def id, do: :rdf
end
