defmodule FeedReader.Media.CandidateTracker do
  @moduledoc """
  Shared bookkeeping for media candidates captured by the built-in XML handlers.

  Parser state must contain `:feed_candidate_sequence` and
  `:item_candidate_sequence`, each initialized with `FeedReader.Media.CandidateSequence.new/0`.
  `path/3` turns the top-first frame stack and current element into a root-to-leaf
  path. A handler decides whether that path is eligible, then `start/2` records
  the candidate's position in the feed or item sequence. `complete/3` stores its
  value when the element closes; finalization therefore retains encounter order
  even when nested candidates close out of order. `reset_item/1` starts a fresh
  sequence for the next item, and `expanded_attributes/2` resolves attribute
  names in the element's namespace scope.

  This module is an internal helper for the built-in format handlers, not a
  public extension API.
  """

  alias FeedReader.Media.CandidateSequence
  alias FeedReader.XML.{Name, NamespaceScope}

  @type scope :: :feed | :item
  @type position :: {scope(), CandidateSequence.position()}

  @spec path([map()], String.t(), NamespaceScope.t()) ::
          [{String.t(), NamespaceScope.t()}]
  def path(frames, name, namespace_scope) do
    ancestors = Enum.map(Enum.reverse(frames), &{&1.name, &1.namespace_scope})
    ancestors ++ [{name, namespace_scope}]
  end

  @spec start(map(), scope() | nil) :: {map(), position() | nil}
  def start(state, nil), do: {state, nil}

  def start(state, scope) when scope in [:feed, :item] do
    key = sequence_key(scope)
    {sequence, position} = state |> Map.fetch!(key) |> CandidateSequence.start()

    {Map.put(state, key, sequence), {scope, position}}
  end

  @spec complete(map(), position(), term()) :: map()
  def complete(state, {scope, position}, candidate) when scope in [:feed, :item] do
    key = sequence_key(scope)
    sequence = Map.fetch!(state, key)
    Map.put(state, key, CandidateSequence.complete(sequence, position, candidate))
  end

  @spec reset_item(map()) :: map()
  def reset_item(state),
    do: Map.put(state, :item_candidate_sequence, CandidateSequence.new())

  @spec expanded_attributes([{String.t(), String.t()}], NamespaceScope.t()) :: map()
  def expanded_attributes(attributes, namespace_scope) do
    Map.new(attributes, fn {name, value} ->
      {Name.attribute(name, namespace_scope), value}
    end)
  end

  defp sequence_key(:feed), do: :feed_candidate_sequence
  defp sequence_key(:item), do: :item_candidate_sequence
end
