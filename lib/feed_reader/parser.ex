defmodule FeedReader.Parser do
  @moduledoc "One-pass local feed parsing used by `FeedReader.stream_file/2`."

  alias FeedReader.{FormatRegistry, Session}

  @default_chunk_size 65_536

  @doc "Creates a session that lazily parses a caller-owned XML file once."
  @spec stream_file(Path.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def stream_file(path, opts) when is_binary(path) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)

    with :ok <- file_exists(path),
         {:ok, format, input} <- detected_input(path, opts) do
      events = event_stream(input, format, opts, chunk_size)
      {:ok, %Session{events: events, fetch: nil}}
    end
  end

  def stream_file(_path, _opts), do: {:error, :invalid_path}

  defp file_exists(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :not_a_file}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec detected_input(Path.t(), keyword()) ::
          {:ok, module(), Enumerable.t()} | {:error, :unknown}
  defp detected_input(path, opts) do
    max_bytes =
      case Keyword.get(opts, :max_detection_bytes, 65_536) do
        value when is_integer(value) and value > 0 -> value
        _invalid -> 0
      end

    {:ok, file} = File.open(path, [:read, :binary])
    prefix = IO.binread(file, max_bytes)
    File.close(file)
    detected = FeedReader.detect_format(prefix, opts)

    case format_module(Keyword.get(opts, :format, detected), opts) do
      nil ->
        {:error, :unknown}

      format ->
        input = File.stream!(path, Keyword.get(opts, :chunk_size, @default_chunk_size), [:raw])
        {:ok, format, strip_utf8_bom(input)}
    end
  end

  @spec format_module(atom(), keyword()) :: module() | nil
  defp format_module(:rss, _opts), do: FeedReader.Formats.RSS
  defp format_module(:atom, _opts), do: FeedReader.Formats.Atom
  defp format_module(:rdf, _opts), do: FeedReader.Formats.RDF

  defp format_module(format, opts) when is_atom(format) do
    formats = FormatRegistry.formats(Keyword.get(opts, :formats, []))

    Enum.find(formats, fn module ->
      Code.ensure_loaded?(module) and function_exported?(module, :id, 0) and
        (module.id() == format or module == format)
    end)
  end

  defp format_module(_format, _opts), do: nil

  defp strip_utf8_bom(input) do
    Stream.transform(input, fn -> {:pending, <<>>} end, &strip_bom_chunk/2, &flush_bom/1)
  end

  defp strip_bom_chunk(chunk, {:pending, prefix}) do
    data = prefix <> chunk

    if byte_size(data) < 3 do
      {[], {:pending, data}}
    else
      output =
        if binary_part(data, 0, 3) == <<0xEF, 0xBB, 0xBF>>,
          do: binary_part(data, 3, byte_size(data) - 3),
          else: data

      emit_bom_chunk(output)
    end
  end

  defp strip_bom_chunk(chunk, :ready), do: {[chunk], :ready}

  defp emit_bom_chunk(<<>>), do: {[], :ready}
  defp emit_bom_chunk(chunk), do: {[chunk], :ready}

  defp flush_bom({:pending, <<>>}), do: []
  defp flush_bom({:pending, prefix}), do: [prefix]
  defp flush_bom(:ready), do: []

  defp event_stream(input, format, opts, chunk_size) do
    Stream.resource(
      fn -> start_parser(input, format, opts, chunk_size) end,
      &next_event/1,
      &stop_parser/1
    )
  end

  defp start_parser(input, format, opts, chunk_size) do
    parent = self()
    reference = make_ref()
    max_queue_bytes = queue_limit(opts)

    {pid, monitor} =
      spawn_monitor(fn ->
        owner_monitor = Process.monitor(parent)

        sink = event_sink(parent, reference, owner_monitor, max_queue_bytes)

        state = format.new_parser_state(sink, opts)

        result =
          Saxy.parse_stream(input, format.handler(), state, character_data_max_length: chunk_size)

        case result do
          {:ok, _state} ->
            send(parent, {reference, :done})

          {:error, reason} ->
            send(parent, {reference, {:event, {:error, reason}}})

          {:halt, state, _rest} when is_map(state) and state.root_closed ->
            send(parent, {reference, :done})

          {:halt, _state, _rest} ->
            send(parent, {reference, {:event, {:error, :parser_halted}}})
        end
      end)

    %{reference: reference, pid: pid, monitor: monitor, done?: false}
  end

  defp next_event(%{done?: true} = state), do: {:halt, state}

  defp next_event(state) do
    send(state.pid, {state.reference, :demand})

    receive do
      {reference, {:event, event}} when reference == state.reference ->
        state = if match?({:error, _reason}, event), do: %{state | done?: true}, else: state
        {[event], state}

      {reference, :done} when reference == state.reference ->
        {:halt, %{state | done?: true}}

      {:DOWN, monitor, :process, _pid, reason} when monitor == state.monitor ->
        if reason == :normal do
          {:halt, %{state | done?: true}}
        else
          {[{:error, reason}], %{state | done?: true}}
        end
    end
  end

  defp stop_parser(%{pid: pid, monitor: monitor}) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp event_sink(parent, reference, owner_monitor, max_queue_bytes) do
    fn event ->
      await_demand(parent, reference, owner_monitor)

      if byte_size(:erlang.term_to_binary(event)) > max_queue_bytes do
        send(
          parent,
          {reference, {:event, {:error, {:resource_limit, :max_queue_bytes, max_queue_bytes}}}}
        )

        exit(:normal)
      else
        send(parent, {reference, {:event, event}})
      end
    end
  end

  defp await_demand(parent, reference, owner_monitor) do
    receive do
      {^reference, :demand} -> :ok
      {:DOWN, ^owner_monitor, :process, ^parent, _reason} -> exit(:normal)
    end
  end

  defp queue_limit(opts) do
    default =
      case Keyword.get(opts, :max_item_bytes, 4_194_304) do
        value when is_integer(value) and value >= 0 -> value
        _invalid -> 4_194_304
      end

    case Keyword.get(opts, :max_queue_bytes, default) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> default
    end
  end
end
