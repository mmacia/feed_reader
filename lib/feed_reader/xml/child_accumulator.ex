defmodule FeedReader.XML.ChildAccumulator do
  @moduledoc """
  Accumulates child values without repeatedly appending to lists.

  A child name added once retains its value; repeated additions are finalized
  as a list in insertion order. `add/3` prepends repeated values, and
  `finalize/1` reverses them to restore that order.
  """

  @type t :: %__MODULE__{values: map()}
  defstruct values: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec add(t(), term(), term()) :: t()
  def add(%__MODULE__{values: values} = accumulator, name, value) do
    entry =
      case Map.fetch(values, name) do
        :error -> {:single, value}
        {:ok, {:single, first}} -> {:repeated, [value, first]}
        {:ok, {:repeated, reversed}} -> {:repeated, [value | reversed]}
      end

    %{accumulator | values: Map.put(values, name, entry)}
  end

  @spec finalize(t()) :: map()
  def finalize(%__MODULE__{values: values}) do
    Map.new(values, fn
      {name, {:single, value}} -> {name, value}
      {name, {:repeated, reversed}} -> {name, Enum.reverse(reversed)}
    end)
  end
end
