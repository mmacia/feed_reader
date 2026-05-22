defmodule FeedReader.TestSupport.ReqErrorAdapter do
  @moduledoc false

  def run(request) do
    {request, %Req.HTTPError{protocol: :http1, reason: :unexpected}}
  end
end
