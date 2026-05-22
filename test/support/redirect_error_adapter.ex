defmodule FeedReader.TestSupport.RedirectErrorAdapter do
  @moduledoc false

  def run(request) do
    {request, %Req.TooManyRedirectsError{max_redirects: 5}}
  end
end
