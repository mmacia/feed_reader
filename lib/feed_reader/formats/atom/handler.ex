defmodule FeedReader.Formats.Atom.Handler do
  @moduledoc false
  @behaviour Saxy.Handler

  alias FeedReader.Formats.Atom
  alias FeedReader.Media
  alias FeedReader.Media.CandidateTracker
  alias FeedReader.XML.ChildAccumulator
  alias FeedReader.XML.{Name, NamespaceScope}
  alias FeedReader.XMLResourceLimits

  @impl true
  def handle_event(_event, _data, %{error: reason} = state) when not is_nil(reason),
    do: {:stop, state}

  @impl true
  def handle_event(event, data, state) when event in [:start_document, :end_document],
    do: account(state, event, data)

  def handle_event(:start_element, {name, attrs}, state) do
    namespace_scope = NamespaceScope.enter(state.namespace_scope, attrs)
    owner = owner(name, namespace_scope, state.frames)
    state = if owner == :entry, do: emit_feed(state), else: state
    state = if owner == :entry, do: CandidateTracker.reset_item(state), else: state
    path = CandidateTracker.path(state.frames, name, namespace_scope)

    {state, candidate_position} =
      CandidateTracker.start(state, candidate_scope(path, state))

    limits = start_scope(state.limits, owner)

    case XMLResourceLimits.account_event(limits, :start_element, {name, attrs}) do
      {:ok, limits} ->
        frame = %{
          name: name,
          child_name: child_name(name, namespace_scope),
          attrs: Map.new(attrs),
          children: ChildAccumulator.new(),
          text: "",
          markup: [],
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
      {:ok,
       %{
         state
         | limits: limits,
           frames: [%{frame | text: frame.text <> data, markup: [frame.markup, data]} | rest]
       }}
    else
      {:error, reason} -> {:stop, %{state | error: reason}}
      [] -> {:stop, %{state | error: :invalid_sax_event}}
    end
  end

  def handle_event(:end_element, name, state) do
    with {:ok, limits} <- XMLResourceLimits.account_event(state.limits, :end_element, name),
         [frame | rest] <- state.frames do
      value =
        if is_nil(frame.candidate_position) or preserve_candidate_raw?(frame),
          do: element_value(frame)

      limits = end_scope(limits, frame.owner, rest)

      state = %{
        state
        | limits: limits,
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
      {:error, reason} -> {:stop, %{state | limits: state.limits, error: reason}}
    end
  end

  defp start_scope(limits, :feed), do: XMLResourceLimits.set_scope(limits, :feed)
  defp start_scope(limits, :entry), do: XMLResourceLimits.set_scope(limits, :item)
  defp start_scope(limits, _owner), do: limits

  defp end_scope(limits, :feed, _parents),
    do: XMLResourceLimits.set_scope(limits, :none)

  defp end_scope(limits, :entry, [%{owner: :feed} | _]),
    do: XMLResourceLimits.set_scope(limits, :feed)

  defp end_scope(limits, :entry, _parents),
    do: XMLResourceLimits.set_scope(limits, :none)

  defp end_scope(limits, _owner, _parents), do: limits

  defp owner(name, namespace_scope, []) do
    cond do
      atom_name?(name, namespace_scope, "feed") -> :feed
      atom_name?(name, namespace_scope, "entry") -> :entry
      true -> nil
    end
  end

  defp owner(name, namespace_scope, [%{owner: :feed} | _]) do
    if atom_name?(name, namespace_scope, "entry"), do: :entry
  end

  defp owner(_name, _namespace_scope, _frames), do: nil

  # Prefixed Atom names are enabled together with expanded-name metadata lookup.
  defp atom_name?(name, namespace_scope, local_name) do
    Name.core_name?(name, namespace_scope, :atom, local_name)
  end

  defp child_name(name, namespace_scope) do
    {namespace, local_name} = Name.element(name, namespace_scope)

    if Name.core_name?(name, namespace_scope, :atom, local_name) do
      local_name
    else
      if namespace, do: {namespace, local_name}, else: name
    end
  end

  defp emit_feed(%{feed: nil, frames: frames} = state) do
    data =
      frames
      |> List.last()
      |> then(fn
        %{owner: :feed, children: children} -> ChildAccumulator.finalize(children)
        _ -> %{}
      end)

    state = %{state | feed: data} |> cache_normalized_feed()
    if is_nil(state.error), do: state.event_sink.({:feed, state.normalized_feed})
    state
  end

  defp emit_feed(state), do: state

  defp element_value(%{attrs: attrs, children: children, text: text, markup: markup}) do
    children = ChildAccumulator.finalize(children)
    value = Map.merge(attrs, children)
    value = if text == "", do: value, else: Map.put(value, "_text", String.trim(text))
    value = Map.put(value, "_markup", markup)
    if map_size(value) == 1, do: String.trim(text), else: value
  end

  defp close_element(%{owner: :entry}, item, state) do
    state = cache_normalized_feed(state)

    Media.Normalizer.emit_item_result(
      Atom.normalize_item_result(
        item,
        state.item_candidate_sequence,
        state.normalized_feed,
        state.opts
      ),
      state
    )
  end

  defp close_element(%{candidate_position: {_scope, _position}} = frame, value, state) do
    candidate = finalize_candidate(frame)
    state = CandidateTracker.complete(state, frame.candidate_position, candidate)

    if preserve_candidate_raw?(frame), do: append_child(frame, value, state), else: {:ok, state}
  end

  defp close_element(%{owner: :feed}, feed, %{feed: nil, frames: []} = state) do
    state = %{state | feed: feed} |> cache_normalized_feed()

    if state.error do
      {:stop, state}
    else
      state.event_sink.({:feed, state.normalized_feed})
      halt_at_root(state)
    end
  end

  defp close_element(%{owner: :feed}, _feed, %{frames: []} = state),
    do: halt_at_root(state)

  defp close_element(frame, value, %{frames: [parent | rest]} = state) do
    append_child(frame, value, %{state | frames: [parent | rest]})
  end

  defp close_element(_frame, _value, state), do: {:ok, state}

  defp halt_at_root(state), do: {:halt, %{state | root_closed: true}}

  defp render(frame) do
    attrs = Enum.map_join(frame.attrs, " ", fn {key, value} -> ~s(#{key}="#{value}") end)
    opening = if attrs == "", do: "<#{frame.name}>", else: "<#{frame.name} #{attrs}>"
    [opening, frame.markup, "</#{frame.name}>"]
  end

  defp cache_normalized_feed(%{normalized_feed: nil} = state) do
    case Atom.normalize_feed_result(state, state.opts) do
      {:ok, feed} -> %{state | normalized_feed: feed}
      {:error, reason} -> %{state | error: reason}
    end
  end

  defp cache_normalized_feed(state), do: state

  defp candidate_scope(path, state) do
    if Media.CandidatePath.eligible?(:atom, path) do
      case {length(path), state.normalized_feed} do
        {2, nil} -> :feed
        {2, _normalized_feed} -> nil
        {_entry_path, _normalized_feed} -> :item
      end
    end
  end

  defp finalize_candidate(frame) do
    {children, text} =
      if media_rss_candidate?(frame),
        do: {frame.children, ""},
        else: {ChildAccumulator.new(), atom_text(frame)}

    Media.Candidate.finalize(
      Name.element(frame.name, frame.namespace_scope),
      CandidateTracker.expanded_attributes(frame.attrs, frame.namespace_scope),
      children,
      text
    )
  end

  defp media_rss_candidate?(frame) do
    {namespace, local_name} = Name.element(frame.name, frame.namespace_scope)
    namespace == "http://search.yahoo.com/mrss/" and local_name in ["content", "thumbnail"]
  end

  defp atom_text(frame) do
    if Enum.any?(
         ["icon", "logo"],
         &Name.core_name?(frame.name, frame.namespace_scope, :atom, &1)
       ),
       do: String.trim(frame.text),
       else: ""
  end

  defp preserve_candidate_raw?(frame) do
    Enum.any?(
      ["icon", "logo", "link", "content"],
      &Name.core_name?(frame.name, frame.namespace_scope, :atom, &1)
    )
  end

  defp append_child(frame, value, %{frames: [parent | rest]} = state) do
    child_name =
      if parent.candidate_position,
        do: Name.element(frame.name, frame.namespace_scope),
        else: frame.child_name

    children = ChildAccumulator.add(parent.children, child_name, value)
    markup = [parent.markup, render(frame)]
    {:ok, %{state | frames: [%{parent | children: children, markup: markup} | rest]}}
  end

  defp append_child(_frame, _value, state), do: {:ok, state}
end
