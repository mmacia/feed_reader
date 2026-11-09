defmodule FeedReader.XML.NamespaceScope do
  @moduledoc """
  Tracks XML namespace bindings as elements open and close.

  Prefixes are aliases, so names must ultimately be matched by namespace URI
  rather than by a particular spelling such as `media` or `m`. Prefix bindings
  can change in nested elements and revert when those elements close; this
  helper provides the scope tracking needed for namespace-aware SAX matching.

  Enter an element with its attributes to apply any `xmlns` declarations, then
  leave it to restore the parent scope. `uri/2` returns the URI bound to a
  prefix, using the empty prefix for the default namespace; unbound or
  undeclared prefixes return `nil`.
  """

  @type t :: %__MODULE__{scopes: [map()]}
  defstruct scopes: [%{}]

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec enter(t(), [{String.t(), String.t()}]) :: t()
  def enter(%__MODULE__{scopes: [current | rest]} = scope, attributes) do
    bindings =
      Enum.reduce(attributes, current, fn
        {"xmlns", uri}, bindings ->
          Map.put(bindings, "", uri)

        {"xmlns:" <> prefix, uri}, bindings when prefix != "" ->
          Map.put(bindings, prefix, uri)

        _attribute, bindings ->
          bindings
      end)

    %{scope | scopes: [bindings, current | rest]}
  end

  @spec leave(t()) :: t()
  def leave(%__MODULE__{scopes: [_current, parent | rest]} = scope),
    do: %{scope | scopes: [parent | rest]}

  def leave(scope), do: scope

  @spec uri(t(), String.t()) :: String.t() | nil
  def uri(%__MODULE__{scopes: [bindings | _]}, prefix) do
    case Map.get(bindings, prefix) do
      "" -> nil
      uri -> uri
    end
  end

  @spec bound?(t(), String.t()) :: boolean()
  def bound?(%__MODULE__{scopes: [bindings | _]}, prefix), do: Map.has_key?(bindings, prefix)
end
