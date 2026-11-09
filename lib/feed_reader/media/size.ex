defmodule FeedReader.Media.Size do
  @moduledoc false

  alias FeedReader.Media

  @doc """
  Adds one media value's embedded ETF size to a serialized-size lower bound.

  ETF (Erlang External Term Format) adds a one-byte version marker when a term
  is serialized on its own. A media struct embedded in a serialized feed or item
  has no separate marker, so this subtracts that byte from `:erlang.external_size/1`.
  The full media struct encoding is counted, while the surrounding event and list
  encoding are omitted; the result is therefore a lower bound for the event size.
  """
  @spec add(non_neg_integer(), Media.t()) :: non_neg_integer()
  def add(lower_bound, %Media{} = media) when is_integer(lower_bound) and lower_bound >= 0 do
    lower_bound + :erlang.external_size(media) - 1
  end
end
