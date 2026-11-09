defmodule FeedReader.Formats.RDF.Handler do
  @moduledoc false
  @behaviour Saxy.Handler

  alias FeedReader.Formats.RDF
  alias FeedReader.Media
  alias FeedReader.Media.CandidateTracker
  alias FeedReader.XML.ChildAccumulator
  alias FeedReader.XML.{Name, NamespaceScope}
  alias FeedReader.XMLResourceLimits

  @rdf_namespace "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

  @impl true
  def handle_event(event, data, state) when event in [:start_document, :end_document],
    do: account(state, event, data)

  def handle_event(:start_element, {name, attrs}, state) do
    namespace_scope = NamespaceScope.enter(state.namespace_scope, attrs)
    owner = owner(name, namespace_scope, state.frames)
    state = if owner == :item, do: emit_feed_before_item(state), else: state
    state = if owner == :item, do: CandidateTracker.reset_item(state), else: state
    path = CandidateTracker.path(state.frames, name, namespace_scope)

    {state, candidate_position} =
      CandidateTracker.start(state, candidate_scope(path, attrs, state))

    limits = start_scope(state.limits, owner)

    case XMLResourceLimits.account_event(limits, :start_element, {name, attrs}) do
      {:ok, limits} ->
        frame = %{
          name: name,
          child_name: child_name(name, namespace_scope),
          attrs: Map.new(attrs),
          children: ChildAccumulator.new(),
          text: "",
          owner: owner,
          namespace_scope: namespace_scope,
          candidate_position: candidate_position
        }

        {:ok,
         %{
           state
           | limits: limits,
             namespace_scope: namespace_scope,
             frames: [frame | state.frames]
         }}

      {:error, reason} ->
        {:stop, %{state | limits: limits, error: reason}}
    end
  end

  def handle_event(event, data, state) when event in [:characters, :cdata] do
    with {:ok, limits} <- XMLResourceLimits.account_event(state.limits, event, data),
         [frame | rest] <- state.frames do
      {:ok, %{state | limits: limits, frames: [%{frame | text: frame.text <> data} | rest]}}
    else
      {:error, reason} -> {:stop, %{state | error: reason}}
      [] -> {:stop, %{state | error: :invalid_sax_event}}
    end
  end

  def handle_event(:end_element, name, state) do
    with {:ok, limits} <- XMLResourceLimits.account_event(state.limits, :end_element, name),
         [frame | rest] <- state.frames do
      state = %{
        state
        | limits: end_scope(limits, frame.owner),
          namespace_scope: NamespaceScope.leave(state.namespace_scope),
          frames: rest
      }

      value = if is_nil(frame.candidate_position), do: element_value(frame)
      close_element(frame, value, state)
    else
      {:error, reason} -> {:stop, %{state | error: reason}}
      [] -> {:stop, %{state | error: :invalid_sax_event}}
    end
  end

  defp account(state, event, data) do
    case XMLResourceLimits.account_event(state.limits, event, data) do
      {:ok, limits} -> {:ok, %{state | limits: limits}}
      {:error, reason} -> {:stop, %{state | error: reason}}
    end
  end

  defp start_scope(limits, :channel), do: XMLResourceLimits.set_scope(limits, :feed)
  defp start_scope(limits, :item), do: XMLResourceLimits.set_scope(limits, :item)
  defp start_scope(limits, _owner), do: limits

  defp end_scope(limits, owner) when owner in [:channel, :item],
    do: XMLResourceLimits.set_scope(limits, :none)

  defp end_scope(limits, _owner), do: limits

  defp owner(name, namespace_scope, []) do
    if rdf_root?(name, namespace_scope), do: :rdf_root
  end

  defp owner(name, namespace_scope, [%{owner: :rdf_root} | _]) do
    cond do
      rss_child?(name, namespace_scope, "channel") -> :channel
      rss_child?(name, namespace_scope, "item") -> :item
      true -> nil
    end
  end

  defp owner(_name, _namespace_scope, _frames), do: nil

  defp rdf_root?(name, namespace_scope),
    do: Name.core_name?(name, namespace_scope, :rdf, "RDF")

  defp rss_child?(name, namespace_scope, local_name) do
    Name.core_name?(name, namespace_scope, :rss, local_name)
  end

  defp child_name(name, namespace_scope) do
    {namespace, local_name} = Name.element(name, namespace_scope)

    cond do
      Name.core_name?(name, namespace_scope, :rss, local_name) -> local_name
      is_nil(namespace) or String.contains?(name, ":") -> name
      true -> {namespace, local_name}
    end
  end

  defp emit_feed_before_item(%{channel: nil, normalized_feed: nil} = state) do
    state |> Map.put(:channel, %{}) |> emit_feed()
  end

  defp emit_feed_before_item(state), do: state

  defp element_value(%{attrs: attrs, children: children, text: text}) do
    children = ChildAccumulator.finalize(children)
    text = String.trim(text)

    if map_size(attrs) == 0 and map_size(children) == 0,
      do: text,
      else: put_text(Map.merge(attrs, children), text)
  end

  defp put_text(value, ""), do: value
  defp put_text(value, text), do: Map.put(value, "_text", text)

  defp close_element(%{owner: :item}, item, state) do
    state = cache_normalized_feed(state)

    Media.Normalizer.emit_item_result(
      RDF.normalize_item_result(
        item,
        state.item_candidate_sequence,
        state.normalized_feed,
        state.opts
      ),
      state
    )
  end

  defp close_element(%{candidate_position: {_scope, _position}} = frame, _value, state) do
    candidate =
      Media.Candidate.finalize(
        Name.element(frame.name, frame.namespace_scope),
        CandidateTracker.expanded_attributes(frame.attrs, frame.namespace_scope),
        frame.children,
        frame.text
      )

    {:ok, CandidateTracker.complete(state, frame.candidate_position, candidate)}
  end

  defp close_element(%{owner: :channel}, channel, %{channel: nil} = state) do
    state = %{state | channel: channel}
    state = emit_feed(state)
    if state.error, do: {:stop, state}, else: {:ok, state}
  end

  defp close_element(frame, value, %{frames: [parent | rest]} = state) do
    append_child(frame, value, %{state | frames: [parent | rest]})
  end

  defp close_element(_frame, _value, %{frames: []} = state),
    do: {:halt, %{state | root_closed: true}}

  defp emit_feed(state) do
    state = cache_normalized_feed(state)

    if is_nil(state.error), do: state.event_sink.({:feed, state.normalized_feed})

    state
  end

  defp cache_normalized_feed(%{normalized_feed: nil} = state) do
    case RDF.normalize_feed_result(state, state.opts) do
      {:ok, feed} -> %{state | normalized_feed: feed}
      {:error, reason} -> %{state | error: reason}
    end
  end

  defp cache_normalized_feed(state), do: state

  defp candidate_scope(path, attrs, state) do
    if Media.CandidatePath.eligible?(:rdf, path) do
      [{_root, _root_scope}, {owner, owner_scope} | _] = path

      case {Name.core_name?(owner, owner_scope, :rss, "channel"), state.normalized_feed} do
        {true, nil} -> feed_candidate_scope(attrs, List.last(path))
        {true, _normalized_feed} -> nil
        {false, _normalized_feed} -> :item
      end
    end
  end

  defp feed_candidate_scope(attrs, {_name, namespace_scope}) do
    if rdf_resource_attribute?(attrs, namespace_scope), do: :feed
  end

  defp rdf_resource_attribute?(attrs, namespace_scope) do
    Enum.any?(attrs, fn {name, _value} ->
      Name.attribute(name, namespace_scope) == {@rdf_namespace, "resource"}
    end)
  end

  defp append_child(frame, value, %{frames: [parent | rest]} = state) do
    child_name =
      if parent.candidate_position,
        do: Name.element(frame.name, frame.namespace_scope),
        else: frame.child_name

    children = ChildAccumulator.add(parent.children, child_name, value)
    {:ok, %{state | frames: [%{parent | children: children} | rest]}}
  end
end
