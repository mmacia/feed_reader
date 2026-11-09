defmodule FeedReader.Media.CandidateSequence do
  @moduledoc false

  @type position :: non_neg_integer()
  @type t :: %__MODULE__{
          next_position: position(),
          positions: [position()],
          values: %{optional(position()) => term()}
        }

  defstruct next_position: 0, positions: [], values: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Records a candidate's encounter position before its value is complete."
  @spec start(t()) :: {t(), position()}
  def start(%__MODULE__{next_position: position, positions: positions} = sequence) do
    sequence = %{
      sequence
      | next_position: position + 1,
        positions: [position | positions]
    }

    {sequence, position}
  end

  @doc "Stores the finalized value for a candidate, which may close out of order."
  @spec complete(t(), position(), term()) :: t()
  def complete(%__MODULE__{values: values} = sequence, position, value) do
    %{sequence | values: Map.put(values, position, value)}
  end

  @doc "Returns completed candidate values in their start-position order."
  @spec finalize(t()) :: [term()]
  def finalize(%__MODULE__{positions: positions, values: values}) do
    positions
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(values, &1))
  end
end
