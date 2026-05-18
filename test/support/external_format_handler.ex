defmodule FeedReader.TestSupport.ExternalFormatHandler do
  @moduledoc false
  @behaviour Saxy.Handler

  alias FeedReader.Feed

  @impl true
  def handle_event(:start_document, _data, %{opts: opts} = state) do
    if Keyword.get(opts, :emit_event), do: emit_event(state)
    Enum.each(Keyword.get(opts, :collector_events, []), fn event -> state.event_sink.(event) end)

    {:ok, state}
  end

  def handle_event(:end_document, _data, %{opts: opts} = state) do
    if Keyword.get(opts, :emit_event), do: emit_event(state)

    {:ok, state}
  end

  def handle_event(_event_type, _data, state), do: {:ok, state}

  defp emit_event(state), do: state.event_sink.({:feed, %Feed{title: "External", type: :rss}})
end
