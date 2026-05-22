defmodule FeedReader.TestSupport.TransportClient do
  @moduledoc false

  @behaviour FeedReader.Transport

  @impl true
  def request(url, opts) do
    send(opts[:test_pid], {:transport_request, url})
    {:ok, %{status: 200, headers: [], final_url: url, body: ["test"]}}
  end
end
