defmodule FeedReader.XML.Name do
  @moduledoc """
  Resolves SAX element and attribute names to namespace URI/local-name pairs.

  Element names inherit the default namespace; unprefixed attributes do not.
  `core_name?/4` recognizes the built-in Atom, RSS, and RDF core namespaces and
  their supported namespace-less forms.
  """

  alias FeedReader.XML.NamespaceScope

  @atom_namespace "http://www.w3.org/2005/Atom"
  @rss_namespace "http://purl.org/rss/1.0/"
  @rdf_namespace "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
  @xml_namespace "http://www.w3.org/XML/1998/namespace"
  @xmlns_namespace "http://www.w3.org/2000/xmlns/"

  @type expanded_name :: {String.t() | nil, String.t()}
  @type core_format :: :atom | :rss | :rdf

  @spec element(String.t(), NamespaceScope.t()) :: expanded_name()
  def element(name, scope), do: resolve(name, scope, :element)

  @spec attribute(String.t(), NamespaceScope.t()) :: expanded_name()
  def attribute("xmlns", _scope), do: {@xmlns_namespace, "xmlns"}
  def attribute("xmlns:" <> prefix, _scope), do: {@xmlns_namespace, prefix}
  def attribute(name, scope), do: resolve(name, scope, :attribute)

  @spec core_name?(String.t(), NamespaceScope.t(), core_format(), String.t()) :: boolean()
  def core_name?(name, scope, format, local_name) do
    expected_namespace = core_namespace(format)

    case element(name, scope) do
      {^expected_namespace, ^local_name} -> true
      {nil, ^local_name} -> namespace_less?(name, scope, format, local_name)
      _other -> false
    end
  end

  defp resolve(name, scope, kind) do
    case String.split(name, ":", parts: 2) do
      [local_name] ->
        namespace = if kind == :element, do: NamespaceScope.uri(scope, ""), else: nil
        {namespace, local_name}

      [prefix, local_name] ->
        {prefix_namespace(prefix, scope), local_name}
    end
  end

  defp prefix_namespace("xml", _scope), do: @xml_namespace
  defp prefix_namespace(prefix, scope), do: NamespaceScope.uri(scope, prefix)

  defp core_namespace(:atom), do: @atom_namespace
  defp core_namespace(:rss), do: @rss_namespace
  defp core_namespace(:rdf), do: @rdf_namespace

  defp namespace_less?(name, scope, :rdf, "RDF") do
    unqualified?(name, scope) or
      (name == "rdf:RDF" and not NamespaceScope.bound?(scope, "rdf"))
  end

  defp namespace_less?(name, scope, _format, _local_name), do: unqualified?(name, scope)

  defp unqualified?(name, scope),
    do: not String.contains?(name, ":") and is_nil(NamespaceScope.uri(scope, ""))
end
