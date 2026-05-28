defmodule FeedReader.ReqTransport do
  @moduledoc """
  Req implementation of `FeedReader.Transport`.

  GET responses are returned as raw, lazy chunks. Automatic Req decompression
  is disabled so the later download pipeline can enforce decoded-byte limits.
  Status 400 and 500 responses and transport failures are retried; redirect
  failures and TLS alerts are terminal. The default is five retries after the
  initial request and five redirects.
  """

  @behaviour FeedReader.Transport

  @default_headers [
    {"user-agent", "feedex/1"},
    {"accept-encoding", "gzip, deflate, identity"}
  ]

  @impl true
  @spec request(String.t(), keyword()) ::
          {:ok, FeedReader.Transport.response()} | {:error, term()}
  def request(url, opts \\ [])

  def request(url, opts) when is_binary(url) do
    http_options = Keyword.get(opts, :http_options, [])

    headers = Keyword.get(http_options, :headers, @default_headers)
    etag = Keyword.get(opts, :previous_etag)

    headers =
      if is_binary(etag), do: conditional_headers(headers, etag), else: headers

    request_options =
      http_options
      |> Keyword.put(:headers, headers)
      |> Keyword.put(:into, :self)
      |> Keyword.put(:raw, true)
      |> Keyword.put(:decode_body, false)
      |> Keyword.put(:compressed, false)
      |> Keyword.put(:max_redirects, 5)
      |> Keyword.put(:max_retries, retry_attempts(opts))
      |> Keyword.put(:retry, &retry?/2)
      |> Keyword.put(:retry_delay, retry_delay(opts))

    case Req.run([url: url], request_options) do
      {request, %Req.Response{} = response} ->
        handle_response(request, response)

      {_request, error} ->
        {:error, error_reason(error)}
    end
  end

  def request(_url, _opts), do: {:error, :invalid_url}

  defp handle_response(request, response) do
    case response.status do
      status when status in 200..299 or status == 304 ->
        {:ok,
         %{
           status: status,
           headers: Req.get_headers_list(response),
           final_url: URI.to_string(request.url),
           body: if(status == 304, do: [], else: response.body)
         }}

      403 ->
        {:error, :forbidden}

      404 ->
        {:error, :not_found}

      429 ->
        {:error, :too_many_requests}

      500 ->
        {:error, :internal_server_error}

      status ->
        {:error, {:http_status, status}}
    end
  end

  defp conditional_headers(headers, etag) when is_binary(etag) do
    headers
    |> Enum.reject(fn {name, _value} -> String.downcase(name) == "if-none-match" end)
    |> Kernel.++([{"if-none-match", etag}])
  end

  defp retry_attempts(opts) do
    case Keyword.get(opts, :http_retry_attempts, 5) do
      attempts when is_integer(attempts) and attempts >= 0 -> attempts
      _ -> 5
    end
  end

  defp retry_delay(opts) do
    case Keyword.get(opts, :retry_delay, 0) do
      delay when is_integer(delay) and delay >= 0 -> fn _ -> delay end
      delay when is_function(delay, 1) -> delay
      _ -> fn _ -> 0 end
    end
  end

  defp retry?(_request, %Req.Response{status: status}), do: status in [400, 500]
  defp retry?(_request, %Req.TransportError{reason: {:tls_alert, _}}), do: false
  defp retry?(_request, %Req.TransportError{}), do: true
  defp retry?(_request, %Req.TooManyRedirectsError{}), do: false
  defp retry?(_request, _error), do: false

  defp error_reason(%Req.TransportError{reason: {:tls_alert, {reason, _message}}}), do: reason
  defp error_reason(%Req.TransportError{reason: reason}), do: reason
  defp error_reason(%Req.TooManyRedirectsError{} = error), do: error
  defp error_reason(error), do: error
end
