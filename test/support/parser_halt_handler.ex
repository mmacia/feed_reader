defmodule FeedReader.TestSupport.ParserHaltHandler do
  @behaviour Saxy.Handler

  @impl true
  def handle_event(_event, _data, _state), do: {:halt, :stopped}
end
