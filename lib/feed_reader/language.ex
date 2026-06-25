defmodule FeedReader.Language do
  @moduledoc false

  @max_detection_chars 20_000

  @doc "Detects language from bounded text and falls back to English on failure."
  @spec detect(binary() | [binary() | nil]) :: atom()
  def detect(text) when is_binary(text), do: text |> sample() |> detect_sample()

  def detect(texts) when is_list(texts), do: texts |> sample_texts() |> detect_sample()
  def detect(_text), do: :en

  defp sample_texts(texts) do
    Enum.reduce_while(texts, "", fn
      text, acc when is_binary(text) ->
        append_sample(acc, text)

      _text, acc ->
        {:cont, acc}
    end)
  end

  defp append_sample(acc, text) do
    if String.length(acc) >= @max_detection_chars do
      {:halt, acc}
    else
      separator = if acc == "", do: "", else: "\n"
      remaining = @max_detection_chars - String.length(acc) - String.length(separator)
      sample = String.slice(text, 0, max(remaining, 0))
      {:cont, acc <> separator <> sample}
    end
  end

  defp sample(text), do: String.slice(text, 0, @max_detection_chars)

  defp detect_sample(text) do
    text
    |> HtmlSanitizeEx.strip_tags()
    |> detect_with_tongue()
  rescue
    _error -> :en
  catch
    :exit, _reason -> :en
  end

  defp detect_with_tongue(text) do
    case Tongue.detect(text) do
      [{language, _score} | _rest] -> language
      _none -> :en
    end
  end
end
