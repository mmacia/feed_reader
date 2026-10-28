defmodule FeedReader.VerifiedParser do
  @moduledoc "Validates a complete XML pass before returning a feed event session."

  alias FeedReader.{Parser, Session}

  @default_max_passes 5

  @doc "Validates a local or library-owned file before exposing its events."
  @spec stream_file(Path.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def stream_file(path, opts) do
    max_passes = positive_option(opts, :max_parse_passes, @default_max_passes)

    with :ok <- validate(path, opts),
         :ok <- require_delivery_pass(max_passes),
         {:ok, %Session{} = session} <- Parser.stream_file(path, opts) do
      resource = owned_resource(opts)

      events =
        Stream.transform(
          session.events,
          fn -> :ok end,
          fn event, state -> {[event], state} end,
          fn _state -> close_owned_resource(resource) end
        )

      {:ok, %Session{session | events: events, resource: resource}}
    end
  end

  defp validate(path, opts) do
    with {:ok, %{events: events}} <- Parser.stream_file(path, opts) do
      case Enum.find(events, &match?({:error, _}, &1)) do
        {:error, reason} -> {:error, reason}
        nil -> :ok
      end
    end
  end

  defp require_delivery_pass(limit) when limit >= 2, do: :ok
  defp require_delivery_pass(limit), do: {:error, {:resource_limit, :max_parse_passes, limit}}

  defp owned_resource(opts) do
    case Keyword.get(opts, :owned_source_path) do
      path when is_binary(path) -> %{path: path}
      _ -> nil
    end
  end

  defp close_owned_resource(nil), do: :ok

  defp close_owned_resource(resource),
    do: FeedReader.close(%Session{resource: resource})

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
