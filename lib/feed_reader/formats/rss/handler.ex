defmodule FeedReader.Formats.RSS.Handler do
  @moduledoc false
  @behaviour Saxy.Handler

  alias FeedReader.Formats.RSS

  alias FeedReader.Media
  alias FeedReader.Media.CandidateTracker

  alias FeedReader.XML.ChildAccumulator
  alias FeedReader.XML.{Name, NamespaceScope}
  alias FeedReader.XMLResourceLimits

  @impl true
  def handle_event(_event, _data, %{error: reason} = state) when not is_nil(reason),
    do: {:stop, state}

  def handle_event(event, data, state) when event in [:start_document, :end_document],
    do: account(state, event, data)

  def handle_event(:start_element, {name, attrs}, state) do
    namespace_scope = NamespaceScope.enter(state.namespace_scope, attrs)
    owner = owner(name, namespace_scope, state.frames)
    state = if owner == :item, do: emit_feed_before_item(state), else: state

    state = if owner == :item, do: CandidateTracker.reset_item(state), else: state
    path = CandidateTracker.path(state.frames, name, namespace_scope)

    {state, candidate_position} =
      CandidateTracker.start(state, candidate_scope(path, state))

    limits = scope(state.limits, owner, :start_element)

    case XMLResourceLimits.account_event(limits, :start_element, {name, attrs}) do
      {:ok, limits} ->
        frame = %{
          name: name,
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

  def handle_event(:characters, data, state) do
    with {:ok, limits} <- XMLResourceLimits.account_event(state.limits, :characters, data),
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
      value = if is_nil(frame.candidate_position), do: element_value(frame)

      state = %{
        state
        | limits: scope(limits, frame.owner, :end_element),
          namespace_scope: NamespaceScope.leave(state.namespace_scope),
          frames: rest
      }

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

  defp scope(limits, :channel, :start_element), do: XMLResourceLimits.set_scope(limits, :feed)
  defp scope(limits, :item, :start_element), do: XMLResourceLimits.set_scope(limits, :item)
  defp scope(limits, :item, :end_element), do: XMLResourceLimits.set_scope(limits, :feed)
  defp scope(limits, :channel, :end_element), do: XMLResourceLimits.set_scope(limits, :none)
  defp scope(limits, _owner, _event), do: limits

  defp owner(name, namespace_scope, []) do
    if Name.core_name?(name, namespace_scope, :rss, "rss"), do: :rss_root
  end

  defp owner(name, namespace_scope, [%{owner: :rss_root} | _]) do
    if Name.core_name?(name, namespace_scope, :rss, "channel"), do: :channel
  end

  defp owner(name, namespace_scope, [%{owner: :channel} | _]) do
    if Name.core_name?(name, namespace_scope, :rss, "item"), do: :item
  end

  defp owner(_name, _namespace_scope, _frames), do: nil

  defp emit_feed_before_item(
         %{
           channel: nil,
           normalized_feed: nil,
           frames: [%{owner: :channel, children: children} | _]
         } = state
       ) do
    children = ChildAccumulator.finalize(children)
    state = %{state | channel: children}
    emit_feed(state)
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
      RSS.normalize_item_result(
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

  defp close_element(%{owner: :channel}, _channel, state), do: {:ok, state}

  defp close_element(%{owner: :rss_root}, _feed, %{frames: []} = state),
    do: {:halt, %{state | root_closed: true}}

  defp close_element(frame, value, %{frames: [parent | rest]} = state) do
    child_name =
      if parent.candidate_position,
        do: Name.element(frame.name, frame.namespace_scope),
        else: child_name(frame.name, frame.namespace_scope)

    children = ChildAccumulator.add(parent.children, child_name, value)
    {:ok, %{state | frames: [%{parent | children: children} | rest]}}
  end

  defp close_element(_name, _value, state), do: {:ok, state}

  defp emit_feed(state) do
    state = cache_normalized_feed(state)

    if is_nil(state.error), do: state.event_sink.({:feed, state.normalized_feed})

    state
  end

  defp cache_normalized_feed(%{normalized_feed: nil} = state) do
    case RSS.normalize_feed_result(state, state.opts) do
      {:ok, feed} -> %{state | normalized_feed: feed}
      {:error, reason} -> %{state | error: reason}
    end
  end

  defp cache_normalized_feed(state), do: state

  defp candidate_scope(path, state) do
    if Media.CandidatePath.eligible?(:rss, path) do
      case {length(path), state.normalized_feed} do
        {3, nil} -> :feed
        {3, _normalized_feed} -> nil
        {_item_path, _normalized_feed} -> :item
      end
    end
  end

  defp child_name(name, namespace_scope) do
    {namespace, local_name} = Name.element(name, namespace_scope)

    cond do
      Name.core_name?(name, namespace_scope, :rss, local_name) -> local_name
      is_nil(namespace) or String.contains?(name, ":") -> name
      true -> {namespace, local_name}
    end
  end
end
