defmodule FeedReader.TempFile do
  @moduledoc false

  @spec random_file(String.t()) :: String.t()
  def random_file(base_name \\ "feed_reader") do
    filename =
      "#{base_name}-#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}.xml"

    Path.join(System.tmp_dir!(), filename)
  end
end
