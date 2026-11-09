defmodule FeedReader.Media.CandidatePath do
  @moduledoc false

  alias FeedReader.XML.{Name, NamespaceScope}

  @media_rss_namespace "http://search.yahoo.com/mrss/"

  @type element :: {String.t(), NamespaceScope.t()}
  @type format :: :rss | :atom | :rdf

  @doc "Checks whether a scoped element path is a supported core media location."
  @spec eligible?(format(), [element()]) :: boolean()
  def eligible?(:rss, [root, channel, image]) do
    core?(root, :rss, "rss") and core?(channel, :rss, "channel") and
      core?(image, :rss, "image")
  end

  def eligible?(:rss, [root, channel, item, candidate]) do
    rss_item?(root, channel, item) and
      (core?(candidate, :rss, "enclosure") or media_candidate?(candidate))
  end

  def eligible?(:atom, [feed, candidate]) do
    core?(feed, :atom, "feed") and
      Enum.any?(["icon", "logo"], &core?(candidate, :atom, &1))
  end

  def eligible?(:atom, [feed, entry, candidate]) do
    core?(feed, :atom, "feed") and core?(entry, :atom, "entry") and
      (Enum.any?(["link", "content"], &core?(candidate, :atom, &1)) or
         media_candidate?(candidate))
  end

  def eligible?(:rdf, [root, owner, candidate]) do
    core?(root, :rdf, "RDF") and
      ((core?(owner, :rss, "channel") and core?(candidate, :rss, "image")) or
         (core?(owner, :rss, "item") and media_candidate?(candidate)))
  end

  def eligible?(:rss, [root, channel, item, group, candidate]) do
    rss_item?(root, channel, item) and
      ((media?(group, "group") and media_candidate?(candidate)) or
         (media?(group, "content") and media?(candidate, "thumbnail")))
  end

  def eligible?(:atom, [feed, entry, group, candidate]) do
    atom_entry?(feed, entry) and
      ((media?(group, "group") and media_candidate?(candidate)) or
         (media?(group, "content") and media?(candidate, "thumbnail")))
  end

  def eligible?(:rdf, [root, item, group, candidate]) do
    rdf_item?(root, item) and
      ((media?(group, "group") and media_candidate?(candidate)) or
         (media?(group, "content") and media?(candidate, "thumbnail")))
  end

  def eligible?(:rss, [root, channel, item, group, content, thumbnail]) do
    rss_item?(root, channel, item) and media?(group, "group") and
      media?(content, "content") and media?(thumbnail, "thumbnail")
  end

  def eligible?(:atom, [feed, entry, group, content, thumbnail]) do
    atom_entry?(feed, entry) and media?(group, "group") and
      media?(content, "content") and media?(thumbnail, "thumbnail")
  end

  def eligible?(:rdf, [root, item, group, content, thumbnail]) do
    rdf_item?(root, item) and media?(group, "group") and
      media?(content, "content") and media?(thumbnail, "thumbnail")
  end

  def eligible?(_format, _path), do: false

  defp core?({name, namespace_scope}, format, local_name),
    do: Name.core_name?(name, namespace_scope, format, local_name)

  defp rss_item?(root, channel, item),
    do:
      core?(root, :rss, "rss") and core?(channel, :rss, "channel") and
        core?(item, :rss, "item")

  defp atom_entry?(feed, entry),
    do: core?(feed, :atom, "feed") and core?(entry, :atom, "entry")

  defp rdf_item?(root, item),
    do: core?(root, :rdf, "RDF") and core?(item, :rss, "item")

  defp media_candidate?(element), do: media?(element, "content") or media?(element, "thumbnail")

  defp media?({name, namespace_scope}, local_name),
    do: Name.element(name, namespace_scope) == {@media_rss_namespace, local_name}
end
