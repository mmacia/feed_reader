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
        {:ok, format, normalize_xml_input(input, declared_encoding(prefix))}
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

  defp declared_encoding(prefix) do
    case Regex.run(~r/<\?xml\b[^>]*\bencoding\s*=\s*["']([^"']+)["']/is, prefix,
           capture: :all_but_first
         ) do
      [encoding] -> normalize_encoding(encoding)
      _none -> :utf8
    end
  end

  defp normalize_encoding(encoding) do
    case String.downcase(encoding) do
      value when value in ["iso-8859-1", "latin1", "latin-1"] -> :latin1
      _utf8 -> :utf8
    end
  end

  defp normalize_xml_input(input, encoding) do
    input
    |> normalize_xml_prefix()
    |> transcode_input(encoding)
    |> normalize_encoding_declaration(encoding)
    |> normalize_entities()
    |> normalize_attribute_quotes()
  end

  defp normalize_xml_prefix(input) do
    Stream.transform(
      input,
      fn -> {:leading, <<>>} end,
      &normalize_prefix_chunk/2,
      &flush_prefix/1
    )
  end

  defp normalize_prefix_chunk(chunk, {:leading, prefix}) do
    data = prefix <> chunk

    if bom_prefix?(data) do
      {[], {:leading, data}}
    else
      output =
        if starts_with_bom?(data),
          do: binary_part(data, 3, byte_size(data) - 3),
          else: data

      output = trim_leading_xml_whitespace(output)

      if output == <<>> do
        {[], {:leading, <<>>}}
      else
        {[output], :ready}
      end
    end
  end

  defp normalize_prefix_chunk(chunk, :ready), do: {[chunk], :ready}

  defp bom_prefix?(data) when byte_size(data) < 3,
    do: data == binary_part(<<0xEF, 0xBB, 0xBF>>, 0, byte_size(data))

  defp bom_prefix?(_data), do: false

  defp starts_with_bom?(<<0xEF, 0xBB, 0xBF, _rest::binary>>), do: true
  defp starts_with_bom?(_data), do: false

  defp trim_leading_xml_whitespace(<<char, rest::binary>>) when char in [9, 10, 13, 32],
    do: trim_leading_xml_whitespace(rest)

  defp trim_leading_xml_whitespace(data), do: data

  defp flush_prefix({:leading, <<>>}), do: []
  defp flush_prefix({:leading, prefix}), do: [prefix]
  defp flush_prefix(:ready), do: []

  defp transcode_input(input, :utf8), do: input

  defp transcode_input(input, :latin1),
    do: Stream.map(input, fn chunk -> :unicode.characters_to_binary(chunk, :latin1, :utf8) end)

  defp normalize_encoding_declaration(input, :utf8), do: input

  defp normalize_encoding_declaration(input, :latin1) do
    Stream.transform(
      input,
      fn -> {:prolog, <<>>} end,
      &rewrite_declaration_chunk/2,
      &flush_declaration/1
    )
  end

  defp rewrite_declaration_chunk(chunk, {:prolog, prefix}) do
    data = prefix <> chunk

    case :binary.match(data, "?>") do
      {position, 2} ->
        {declaration, rest} = :erlang.split_binary(data, position + 2)
        {[rewrite_declaration(declaration) <> rest], :ready}

      :nomatch ->
        {[], {:prolog, data}}
    end
  end

  defp rewrite_declaration_chunk(chunk, :ready), do: {[chunk], :ready}

  defp rewrite_declaration(declaration) do
    Regex.replace(
      ~r/(encoding\s*=\s*["'])[^"']+(["'])/i,
      declaration,
      "\\1UTF-8\\2",
      global: false
    )
  end

  defp flush_declaration({:prolog, prefix}), do: [prefix]
  defp flush_declaration(:ready), do: []

  defp normalize_entities(input) do
    Stream.transform(
      input,
      fn -> {:normal, <<>>} end,
      &normalize_entity_chunk/2,
      &flush_entities/1
    )
  end

  defp normalize_entity_chunk(chunk, {mode, pending}) do
    {output, mode, pending} = scan_entities(pending <> chunk, mode, [])
    emit_entity_chunk(output, {mode, pending})
  end

  defp scan_entities(data, :normal, output) do
    case next_markup(data) do
      :none ->
        case partial_markup_prefix(data) do
          :none ->
            {append_output(output, data), :normal, <<>>}

          length ->
            split = byte_size(data) - length

            {append_output(output, binary_part(data, 0, split)), :normal,
             binary_part(data, split, length)}
        end

      {position, :cdata} ->
        {prefix, rest} = :erlang.split_binary(data, position)

        scan_entities(binary_part(rest, 9, byte_size(rest) - 9), :cdata, [
          "<![CDATA[",
          prefix | output
        ])

      {position, :comment} ->
        {prefix, rest} = :erlang.split_binary(data, position)

        scan_entities(binary_part(rest, 4, byte_size(rest) - 4), :comment, [
          "<!--",
          prefix | output
        ])

      {position, :entity} ->
        {prefix, rest} = :erlang.split_binary(data, position)
        normalize_entity_reference(binary_part(rest, 1, byte_size(rest) - 1), [prefix | output])
    end
  end

  defp scan_entities(data, :cdata, output) do
    case :binary.match(data, "]]>") do
      :nomatch ->
        keep = min(byte_size(data), 2)
        split = byte_size(data) - keep

        {append_output(output, binary_part(data, 0, split)), :cdata,
         binary_part(data, split, keep)}

      {position, 3} ->
        {prefix, rest} = :erlang.split_binary(data, position + 3)
        scan_entities(rest, :normal, [prefix | output])
    end
  end

  defp scan_entities(data, :comment, output) do
    case :binary.match(data, "-->") do
      :nomatch ->
        keep = min(byte_size(data), 2)
        split = byte_size(data) - keep

        {append_output(output, binary_part(data, 0, split)), :comment,
         binary_part(data, split, keep)}

      {position, 3} ->
        {prefix, rest} = :erlang.split_binary(data, position + 3)
        scan_entities(rest, :normal, [prefix | output])
    end
  end

  defp next_markup(data) do
    [
      {:cdata, :binary.match(data, "<![CDATA[")},
      {:comment, :binary.match(data, "<!--")},
      {:entity, :binary.match(data, "&")}
    ]
    |> Enum.reduce(:none, &earliest_markup/2)
  end

  defp partial_markup_prefix(<<>>), do: :none

  defp partial_markup_prefix(data) do
    max_length = min(byte_size(data), 8)

    Enum.find_value(max_length..1//-1, :none, fn length ->
      suffix = binary_part(data, byte_size(data) - length, length)

      if suffix in [binary_part("<![CDATA[", 0, length), binary_part("<!--", 0, min(length, 4))],
        do: length,
        else: false
    end)
  end

  defp earliest_markup({_kind, :nomatch}, result), do: result
  defp earliest_markup({kind, {position, _length}}, :none), do: {position, kind}

  defp earliest_markup({kind, {position, _length}}, {current, _current_kind})
       when position < current,
       do: {position, kind}

  defp earliest_markup(_candidate, result), do: result

  defp normalize_entity_reference(data, output) do
    case consume_entity(data, "&") do
      {:complete, entity, rest} ->
        entity = if valid_entity?(entity), do: entity, else: escape_entity(entity)
        scan_entities(rest, :normal, [entity | output])

      {:invalid, entity, rest} ->
        scan_entities(rest, :normal, [escape_entity(entity) | output])

      :incomplete ->
        {output, :normal, "&" <> data}
    end
  end

  defp consume_entity(<<>>, _entity), do: :incomplete
  defp consume_entity(<<";", rest::binary>>, entity), do: {:complete, entity <> ";", rest}

  defp consume_entity(<<char, rest::binary>>, entity)
       when char in [9, 10, 13, 32, 34, 38, 39, 60],
       do: {:invalid, entity, <<char, rest::binary>>}

  defp consume_entity(<<char, rest::binary>>, entity),
    do: consume_entity(rest, entity <> <<char>>)

  defp valid_entity?(entity),
    do: Regex.match?(~r/^&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-f]+);$/i, entity)

  defp escape_entity(entity), do: "&amp;" <> binary_part(entity, 1, byte_size(entity) - 1)

  defp append_output(output, <<>>), do: output
  defp append_output(output, chunk), do: [chunk | output]

  defp emit_entity_chunk(output, state) do
    output = output |> Enum.reverse() |> IO.iodata_to_binary()
    if output == <<>>, do: {[], state}, else: {[output], state}
  end

  defp flush_entities({_mode, <<>>}), do: []
  defp flush_entities({_mode, pending}), do: [pending]

  defp normalize_attribute_quotes(input) do
    Stream.map(input, fn chunk ->
      Regex.replace(
        ~r/(=\")([^\"]*)(\")([^\"]*)(\")(\")(?=\s*(?:\/>|>))/,
        chunk,
        "\\1\\2&quot;\\4&quot;\\6"
      )
    end)
  end

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
