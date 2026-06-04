defmodule FeedReader.TestSupport.TransportClient do
  @moduledoc false

  @behaviour FeedReader.Transport

  @impl true
  def request(url, opts) do
    send(opts[:test_pid], {:transport_request, url})

    case Keyword.get(opts, :request_result) do
      nil ->
        {:ok,
         Keyword.get(opts, :response, %{status: 200, headers: [], final_url: url, body: ["test"]})}

      result ->
        result
    end
  end
end
