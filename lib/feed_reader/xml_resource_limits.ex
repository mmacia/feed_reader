defmodule FeedReader.XMLResourceLimits do
  @moduledoc """
  Accounts SAX events before a format handler retains their data.

  These limits prevent large or pathological feeds from causing unbounded
  parser memory use or work. Although SAX input is incremental, handlers still
  retain feed metadata, attributes, and the current item's content. This module
  makes parsing fail with a resource-limit error before those retained values
  exceed their budgets.

  Call `account_event/3` before updating parser state. Set the scope to `:feed`
  while collecting feed metadata and to `:item` for the current item; starting
  each item resets its byte budget. The defaults bound a document to 1,000,000
  events, depth 256, 128 attributes per element, 64 KiB per attribute, 1 MiB of
  feed metadata, and 4 MiB per item. Limits can be overridden with matching
  `:max_*` options; invalid values use the defaults.
  """

  @enforce_keys [
    :max_xml_events,
    :max_xml_depth,
    :max_attributes_per_element,
    :max_attribute_bytes,
    :max_feed_metadata_bytes,
    :max_item_bytes
  ]
  defstruct max_xml_events: 1_000_000,
            max_xml_depth: 256,
            max_attributes_per_element: 128,
            max_attribute_bytes: 65_536,
            max_feed_metadata_bytes: 1_048_576,
            max_item_bytes: 4_194_304,
            events: 0,
            depth: 0,
            feed_metadata_bytes: 0,
            item_bytes: 0,
            scope: :none

  @type scope :: :none | :feed | :item
  @type t :: %__MODULE__{}
  @type limit_error :: {:resource_limit, atom(), non_neg_integer()}

  @doc "Creates an accounting state using defaults or valid non-negative limits."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      max_xml_events: option(opts, :max_xml_events, 1_000_000),
      max_xml_depth: option(opts, :max_xml_depth, 256),
      max_attributes_per_element: option(opts, :max_attributes_per_element, 128),
      max_attribute_bytes: option(opts, :max_attribute_bytes, 65_536),
      max_feed_metadata_bytes: option(opts, :max_feed_metadata_bytes, 1_048_576),
      max_item_bytes: option(opts, :max_item_bytes, 4_194_304)
    }
  end

  @doc "Selects which retained-data budget subsequent SAX events consume."
  @spec set_scope(t(), scope()) :: t()
  def set_scope(%__MODULE__{} = limits, :item), do: %{limits | scope: :item, item_bytes: 0}

  def set_scope(%__MODULE__{} = limits, scope) when scope in [:none, :feed],
    do: %{limits | scope: scope}

  @doc "Checks one Saxy event and returns updated accounting or a stable limit error."
  @spec account_event(t(), atom(), term()) ::
          {:ok, t()} | {:error, limit_error() | :invalid_sax_event}
  def account_event(%__MODULE__{} = limits, event, data) do
    with {:ok, limits} <- increment_events(limits) do
      account_data(limits, event, data)
    end
  end

  defp increment_events(limits) do
    count = limits.events + 1

    if count > limits.max_xml_events,
      do: limit_error(:max_xml_events, limits.max_xml_events),
      else: {:ok, %{limits | events: count}}
  end

  defp account_data(limits, :start_element, {name, attrs})
       when is_binary(name) and is_list(attrs) do
    depth = limits.depth + 1

    with :ok <- within(depth, limits.max_xml_depth, :max_xml_depth),
         {:ok, bytes} <- attribute_bytes(attrs, limits.max_attribute_bytes),
         :ok <-
           within(length(attrs), limits.max_attributes_per_element, :max_attributes_per_element) do
      add_bytes(%{limits | depth: depth}, bytes + byte_size(name))
    end
  end

  defp account_data(limits, :end_element, name) when is_binary(name) and limits.depth > 0 do
    with {:ok, limits} <- add_bytes(limits, byte_size(name)) do
      {:ok, %{limits | depth: limits.depth - 1}}
    end
  end

  defp account_data(limits, event, data) when event in [:characters, :cdata] and is_binary(data),
    do: add_bytes(limits, byte_size(data))

  defp account_data(limits, event, _data)
       when event in [:start_document, :end_document],
       do: {:ok, limits}

  defp account_data(_limits, _event, _data), do: {:error, :invalid_sax_event}

  defp attribute_bytes(attrs, max_attribute_bytes) do
    Enum.reduce_while(attrs, {:ok, 0}, fn
      {name, value}, {:ok, total} when is_binary(name) and is_binary(value) ->
        bytes = byte_size(name) + byte_size(value)

        if bytes > max_attribute_bytes do
          {:halt, limit_error(:max_attribute_bytes, max_attribute_bytes)}
        else
          {:cont, {:ok, total + bytes}}
        end

      _attribute, _acc ->
        {:halt, {:error, :invalid_sax_event}}
    end)
  end

  defp add_bytes(limits, bytes) do
    case limits.scope do
      :feed ->
        next = limits.feed_metadata_bytes + bytes

        if next > limits.max_feed_metadata_bytes,
          do: limit_error(:max_feed_metadata_bytes, limits.max_feed_metadata_bytes),
          else: {:ok, %{limits | feed_metadata_bytes: next}}

      :item ->
        next = limits.item_bytes + bytes

        if next > limits.max_item_bytes,
          do: limit_error(:max_item_bytes, limits.max_item_bytes),
          else: {:ok, %{limits | item_bytes: next}}

      :none ->
        {:ok, limits}
    end
  end

  defp within(value, max, key), do: if(value > max, do: limit_error(key, max), else: :ok)
  defp limit_error(key, max), do: {:error, {:resource_limit, key, max}}

  defp option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> default
    end
  end
end
