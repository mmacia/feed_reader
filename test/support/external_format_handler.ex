defmodule FeedReader.TestSupport.ExternalFormatHandler do
  @moduledoc false
  @behaviour Saxy.Handler

  @impl true
  def handle_event(_event_type, _data, state), do: {:ok, state}
end
