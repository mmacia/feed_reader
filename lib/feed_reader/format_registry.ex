defmodule FeedReader.FormatRegistry do
  @moduledoc """
  Ordered registry of built-in formats.

  Built-ins are tried in RSS, Atom, then RDF order. Per-call custom formats can
  be appended with `formats/1`; duplicate modules are removed without changing
  the first occurrence's position.
  """

  @builtins [FeedReader.Formats.RSS, FeedReader.Formats.Atom, FeedReader.Formats.RDF]

  @doc "Returns the statically ordered built-in format modules."
  @spec builtins() :: [module()]
  def builtins, do: @builtins

  @doc "Returns built-ins followed by explicitly supplied formats, in stable order."
  @spec formats([module()]) :: [module()]
  def formats(custom_formats) when is_list(custom_formats) do
    Enum.uniq(@builtins ++ custom_formats)
  end
end
