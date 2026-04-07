defmodule FeedReader.Formats.Atom.Handler do
  @moduledoc false
  @behaviour Saxy.Handler

  alias FeedReader.Formats.Atom
  alias FeedReader.XMLResourceLimits

  @impl true
  def handle_event(event, data, state) when event in [:start_document, :end_document],
    do: account(state, event, data)

  def handle_event(:start_element, {name, attrs}, state) do
    limits = start_scope(state.limits, name)

    case XMLResourceLimits.account_event(limits, :start_element, {name, attrs}) do
      {:ok, limits} ->
        state = %{state | limits: limits}
        state = if name == "entry", do: emit_feed(state), else: state
        frame = %{name: name, attrs: Map.new(attrs), children: %{}, text: "", markup: []}
        {:ok, %{state | frames: [frame | state.frames]}}

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
      value = element_value(frame)
      limits = if name == "entry", do: XMLResourceLimits.set_scope(limits, :feed), else: limits
      state = %{state | limits: limits, frames: rest}
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

  defp start_scope(limits, "feed"), do: XMLResourceLimits.set_scope(limits, :feed)
  defp start_scope(limits, "entry"), do: XMLResourceLimits.set_scope(limits, :item)
  defp start_scope(limits, _name), do: limits

  defp emit_feed(%{feed: nil, frames: frames} = state) do
    data = frames |> List.last() |> then(&if(is_map(&1), do: &1.children, else: %{}))
    state = %{state | feed: data}
    state.event_sink.({:feed, Atom.normalize_feed(state, state.opts)})
    state
  end

  defp emit_feed(state), do: state

  defp element_value(%{attrs: attrs, children: children, text: text, markup: markup}) do
    value = Map.merge(attrs, children)
    value = if text == "", do: value, else: Map.put(value, "_text", String.trim(text))
    value = Map.put(value, "_markup", markup)
    if map_size(value) == 1, do: String.trim(text), else: value
  end

  defp close_element(%{name: "entry"}, item, state) do
    state.event_sink.(
      {:item,
       elem(Atom.normalize_item(item, Atom.normalize_feed(state, state.opts), state.opts), 1)}
    )

    {:ok, state}
  end

  defp close_element(%{name: "feed"}, feed, %{feed: nil} = state) do
    state = %{state | feed: feed}
    state.event_sink.({:feed, Atom.normalize_feed(state, state.opts)})
    {:ok, state}
  end

  defp close_element(%{name: "feed"}, _feed, state), do: {:ok, state}

  defp close_element(frame, value, %{frames: [parent | rest]} = state) do
    children = Map.update(parent.children, frame.name, value, &(List.wrap(&1) ++ [value]))
    markup = [parent.markup, render(frame)]
    {:ok, %{state | frames: [%{parent | children: children, markup: markup} | rest]}}
  end

  defp close_element(_frame, _value, state), do: {:ok, state}

  defp render(frame) do
    attrs = Enum.map_join(frame.attrs, " ", fn {key, value} -> ~s(#{key}="#{value}") end)
    opening = if attrs == "", do: "<#{frame.name}>", else: "<#{frame.name} #{attrs}>"
    [opening, frame.markup, "</#{frame.name}>"]
  end
end
