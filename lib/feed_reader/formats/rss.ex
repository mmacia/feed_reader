defmodule FeedReader.Formats.RSS do
  @moduledoc false

  def matches_prefix?(prefix) do
    Regex.match?(~r/<rss\b[^>]*\bversion\s*=\s*(["'])2\.0\1/is, prefix)
  end

  def id, do: :rss
end
