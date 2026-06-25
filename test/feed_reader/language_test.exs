defmodule FeedReader.LanguageTest do
  use ExUnit.Case, async: true

  test "bounds long language detection input and returns a language" do
    text = String.duplicate("This is a long English sentence. ", 100_000)

    assert is_atom(FeedReader.Language.detect(text))
  end

  test "ignores non-text values when building a detection sample" do
    assert FeedReader.Language.detect([nil, 123]) == :en
  end
end
