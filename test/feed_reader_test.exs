defmodule FeedReaderTest do
  use ExUnit.Case, async: true

  test "loads the standalone library namespace" do
    assert Code.ensure_loaded?(FeedReader)
  end
end
