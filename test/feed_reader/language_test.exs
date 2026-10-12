defmodule FeedReader.LanguageTest do
  use ExUnit.Case, async: true

  test "bounds long language detection input and returns a language" do
    text = String.duplicate("This is a long English sentence. ", 100_000)

    assert is_atom(FeedReader.Language.detect(text))
  end

  test "stops adding list entries after the detection limit" do
    text = String.duplicate("This is English text. ", 2_000)

    assert is_atom(FeedReader.Language.detect([text, "This entry is ignored."]))
  end

  test "ignores non-text values when building a detection sample" do
    assert FeedReader.Language.detect([nil, 123]) == :en
  end

  test "detects English from plain text" do
    text = "The quick brown fox jumps over the lazy dog."

    assert FeedReader.Language.detect(text) == :en
  end

  test "detects Portuguese from text and ignores markup" do
    text = "<p>Este é um texto em português com palavras suficientes para detectar o idioma.</p>"

    assert FeedReader.Language.detect(text) == :pt
  end

  test "combines binary list entries and skips non-text values" do
    texts = [nil, "Este é um texto em português", 42, " com palavras suficientes para detectar."]

    assert FeedReader.Language.detect(texts) == :pt
  end

  test "falls back to English for empty and unsupported input" do
    assert FeedReader.Language.detect([]) == :en
    assert FeedReader.Language.detect("") == :en
    assert FeedReader.Language.detect(%{}) == :en
  end

  test "falls back to English when the detector exits on invalid UTF-8" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert FeedReader.Language.detect(<<0xFF>>) == :en
    end)
  end
end
