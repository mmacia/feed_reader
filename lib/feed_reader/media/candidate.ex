defmodule FeedReader.Media.Candidate do
  @moduledoc false

  alias FeedReader.XML.{ChildAccumulator, Name}

  @media_rss_namespace "http://search.yahoo.com/mrss/"

  @type t :: %__MODULE__{
          name: Name.expanded_name(),
          attributes: %{optional(Name.expanded_name()) => String.t()},
          children: map(),
          text: String.t(),
          title: String.t() | nil
        }

  defstruct [:name, attributes: %{}, children: %{}, text: "", title: nil]

  @doc "Finalizes a candidate while preserving names resolved in their own scopes."
  @spec finalize(Name.expanded_name(), map(), ChildAccumulator.t(), String.t()) :: t()
  def finalize(name, attributes, children, text) do
    children = ChildAccumulator.finalize(children)

    %__MODULE__{
      name: name,
      attributes: attributes,
      children: children,
      text: text,
      title: direct_media_title(name, children)
    }
  end

  defp direct_media_title({@media_rss_namespace, local_name}, children)
       when local_name in ["content", "thumbnail"] do
    children
    |> Map.get({@media_rss_namespace, "title"})
    |> List.wrap()
    |> Enum.find_value(&title_text/1)
  end

  defp direct_media_title(_name, _children), do: nil

  defp title_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      title -> title
    end
  end

  defp title_text(%{"_text" => value}), do: title_text(value)
  defp title_text(_value), do: nil
end
