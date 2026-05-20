defmodule FeedReader.Transport do
  @moduledoc """
  Injectable HTTP transport boundary used by remote feed operations.

  Implementations return raw response chunks as an enumerable. The response is
  intentionally not decompressed here; the download layer owns decoded-body
  checksums and decompression.
  """

  @type response :: %{
          required(:status) => pos_integer(),
          required(:headers) => [{String.t(), String.t()}],
          required(:final_url) => String.t(),
          required(:body) => Enumerable.t()
        }

  @callback request(url :: String.t(), opts :: keyword()) ::
              {:ok, response()} | {:error, term()}

  @doc "Dispatches a request to the configured or default HTTP client."
  @spec request(String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def request(url, opts \\ []) do
    client = Keyword.get(opts, :http_client, FeedReader.ReqTransport)
    client.request(url, opts)
  end
end
