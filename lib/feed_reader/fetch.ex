defmodule FeedReader.Fetch do
  @moduledoc """
  HTTP metadata for a completed remote feed fetch.

  The checksum is calculated from the decoded response body. A fetch is only
  present on remote results and sessions; local parsing does not invent HTTP
  metadata.
  """

  @type t :: %__MODULE__{
          etag: String.t() | nil,
          checksum: String.t() | nil,
          final_url: String.t() | nil,
          status: pos_integer() | nil
        }

  defstruct etag: nil,
            checksum: nil,
            final_url: nil,
            status: nil
end
