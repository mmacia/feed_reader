defmodule FeedReader.Formats.Atom do
  @moduledoc false

  def matches_prefix?(prefix), do: Regex.match?(~r/<feed\b/is, prefix)

  def id, do: :atom
end
