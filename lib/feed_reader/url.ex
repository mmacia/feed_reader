defmodule FeedReader.URL do
  @moduledoc false

  @doc "Resolves root-relative URLs against the first valid absolute base."
  @spec resolve_root_relative(String.t() | nil, [String.t() | nil]) :: String.t() | nil
  def resolve_root_relative(nil, _bases), do: nil

  def resolve_root_relative("/" <> _ = url, bases) when is_list(bases) do
    case Enum.find(bases, &absolute?/1) do
      nil -> url
      base -> merge(base, url)
    end
  end

  def resolve_root_relative(url, _bases), do: url

  defp absolute?(url) when is_binary(url) do
    uri = URI.parse(url)
    is_binary(uri.scheme) and is_binary(uri.host)
  rescue
    URI.Error -> false
  end

  defp absolute?(_url), do: false

  defp merge(base, url) do
    URI.merge(base, url) |> URI.to_string()
  rescue
    URI.Error -> url
    ArgumentError -> url
  end
end
