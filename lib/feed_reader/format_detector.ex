defmodule FeedReader.FormatDetector do
  @moduledoc "Internal bounded detection and replay for `FeedReader`."

  alias FeedReader.FormatRegistry

  @default_max_detection_bytes 65_536

  @doc "Returns the detected format id, or `:unknown`, from a bounded prefix."
  @spec detect(binary(), keyword()) :: FeedReader.format_id()
  def detect(content, opts) when is_binary(content) do
    {format, _prefix, _replayable} = detect_and_replay(content, opts)
    format
  end

  def detect(_content, _opts), do: :unknown

  @doc "Returns the detected id, inspected prefix, and replayable input stream."
  @spec detect_and_replay(binary() | Enumerable.t(), keyword()) ::
          {FeedReader.format_id(), binary(), Enumerable.t()}
  def detect_and_replay(content, opts) when is_binary(content) do
    max_bytes = max_detection_bytes(opts)
    prefix_size = min(byte_size(content), max_bytes)
    prefix = binary_part(content, 0, prefix_size)
    remainder = binary_part(content, prefix_size, byte_size(content) - prefix_size)

    {detect_prefix(prefix, opts), prefix, Stream.concat([prefix, remainder])}
  end

  def detect_and_replay(content, opts) do
    max_bytes = max_detection_bytes(opts)

    if max_bytes == 0 do
      {:unknown, "", content}
    else
      state = %{mode: :detect, chunks: [], size: 0, remainder: ""}
      reduce_and_replay(content, state, max_bytes, opts)
    end
  end

  defp reduce_and_replay(content, state, max_bytes, opts) do
    case Enumerable.reduce(content, {:cont, state}, fn chunk, state ->
           consume_chunk(chunk, state, max_bytes)
         end) do
      {:suspended, state, continuation} ->
        prefix = prefix(state)
        rest = Stream.concat([state.remainder], continuation_stream(continuation, state))
        {detect_prefix(prefix, opts), prefix, Stream.concat([prefix], rest)}

      {:done, state} ->
        prefix = prefix(state)
        {detect_prefix(prefix, opts), prefix, [prefix]}

      {:halted, state} ->
        prefix = prefix(state)
        {:unknown, prefix, [prefix]}
    end
  end

  @doc "Checks whether the bounded prefix matches the explicitly selected format."
  @spec validate(binary(), atom() | module(), keyword()) :: boolean()
  def validate(content, format, opts) when is_binary(content) do
    {_detected, prefix, _replayable} = detect_and_replay(content, opts)

    case resolve_format(format, formats(opts)) do
      {:ok, formatter} -> matches?(formatter, prefix)
      :error -> false
    end
  end

  def validate(_content, _format, _opts), do: false

  defp max_detection_bytes(opts) do
    case Keyword.get(opts, :max_detection_bytes, @default_max_detection_bytes) do
      max_bytes when is_integer(max_bytes) and max_bytes > 0 -> max_bytes
      _ -> 0
    end
  end

  defp formats(opts), do: FormatRegistry.formats(Keyword.get(opts, :formats, []))

  defp detect_prefix(prefix, opts) do
    opts
    |> formats()
    |> Enum.find(&matches?(&1, prefix))
    |> format_id()
  end

  defp consume_chunk(chunk, %{mode: :detect} = state, max_bytes) when is_binary(chunk) do
    remaining = max_bytes - state.size
    length = min(byte_size(chunk), remaining)
    prefix_chunk = chunk |> binary_part(0, length) |> :binary.copy()
    state = %{state | chunks: [prefix_chunk | state.chunks], size: state.size + length}
    remainder = binary_part(chunk, length, byte_size(chunk) - length)
    state = %{state | remainder: remainder}

    if state.size == max_bytes, do: {:suspend, state}, else: {:cont, state}
  end

  defp consume_chunk(chunk, %{mode: :replay} = state, _max_bytes) do
    {:suspend, Map.put(state, :replay_chunk, chunk)}
  end

  defp consume_chunk(_chunk, state, _max_bytes), do: {:halt, state}

  defp continuation_stream(continuation, state) do
    Stream.resource(
      fn -> {continuation, %{state | mode: :replay}} end,
      fn {continuation, state} ->
        case continuation.({:cont, state}) do
          {:suspended, next_state, next_continuation} ->
            chunk = Map.fetch!(next_state, :replay_chunk)
            {[chunk], {next_continuation, Map.delete(next_state, :replay_chunk)}}

          {:done, _state} ->
            {:halt, nil}

          {:halted, _state} ->
            {:halt, nil}
        end
      end,
      fn _state -> :ok end
    )
  end

  defp prefix(state), do: state.chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp matches?(format, prefix) do
    Code.ensure_loaded?(format) and function_exported?(format, :matches_prefix?, 1) and
      format.matches_prefix?(prefix)
  end

  defp format_id(nil), do: :unknown

  defp format_id(format) do
    if function_exported?(format, :id, 0), do: format.id(), else: :unknown
  end

  defp resolve_format(format, formats) when is_atom(format) do
    if Code.ensure_loaded?(format) and function_exported?(format, :matches_prefix?, 1) do
      {:ok, format}
    else
      Enum.find_value(formats, :error, &resolve_id(&1, format))
    end
  end

  defp resolve_format(_format, _formats), do: :error

  defp resolve_id(module, id) do
    if Code.ensure_loaded?(module) and function_exported?(module, :id, 0) and module.id() == id,
      do: {:ok, module}
  end
end
