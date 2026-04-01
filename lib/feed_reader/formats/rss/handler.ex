defmodule FeedReader.Formats.RSS.Handler do
  @moduledoc false
  @behaviour Saxy.Handler

  alias FeedReader.Formats.RSS
  alias FeedReader.XMLResourceLimits

  @impl true
  def handle_event(event, data, state) when event in [:start_document, :end_document],
    do: account(state, event, data)

  def handle_event(:start_element, {name, attrs}, state) do
    state = if name == "item", do: emit_feed_before_item(state), else: state
    limits = scope(state.limits, name, :start_element)

    case XMLResourceLimits.account_event(limits, :start_element, {name, attrs}) do
      {:ok, limits} ->
        frame = %{name: name, attrs: Map.new(attrs), children: %{}, text: ""}
        {:ok, %{state | limits: limits, frames: [frame | state.frames]}}

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
      value = element_value(frame)
      state = %{state | limits: scope(limits, name, :end_element), frames: rest}
      close_element(frame.name, value, state)
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

  defp scope(limits, "channel", :start_element), do: XMLResourceLimits.set_scope(limits, :feed)
  defp scope(limits, "item", :start_element), do: XMLResourceLimits.set_scope(limits, :item)
  defp scope(limits, "item", :end_element), do: XMLResourceLimits.set_scope(limits, :feed)
  defp scope(limits, "channel", :end_element), do: XMLResourceLimits.set_scope(limits, :none)
  defp scope(limits, _name, _event), do: limits

  defp emit_feed_before_item(%{channel: nil, frames: [%{children: children} | _]} = state) do
    state = %{state | channel: children}
    state.event_sink.({:feed, RSS.normalize_feed(state, state.opts)})
    state
  end

  defp emit_feed_before_item(state), do: state

  defp element_value(%{attrs: attrs, children: children, text: text}) do
    text = String.trim(text)

    if map_size(attrs) == 0 and map_size(children) == 0,
      do: text,
      else: put_text(Map.merge(attrs, children), text)
  end

  defp put_text(value, ""), do: value
  defp put_text(value, text), do: Map.put(value, "_text", text)

  defp close_element("item", item, state) do
    state.event_sink.(
      {:item,
       RSS.normalize_item(item, RSS.normalize_feed(state, state.opts), state.opts) |> elem(1)}
    )

    {:ok, state}
  end

  defp close_element("channel", channel, %{channel: nil} = state) do
    state = %{state | channel: channel}
    state.event_sink.({:feed, RSS.normalize_feed(state, state.opts)})
    {:ok, state}
  end

  defp close_element("channel", _channel, state), do: {:ok, state}

  defp close_element(name, value, %{frames: [parent | rest]} = state) do
    children = Map.update(parent.children, name, value, &(List.wrap(&1) ++ [value]))
    {:ok, %{state | frames: [%{parent | children: children} | rest]}}
  end

  defp close_element(_name, _value, state), do: {:ok, state}
end
