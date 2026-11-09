defmodule FeedReader.Media do
  @moduledoc """
  A format-neutral media resource.

  `url`, `kind`, and `role` are required. The parser uses `:image`, `:audio`,
  `:video`, or `:unknown` for `kind`, and `:content`, `:thumbnail`, `:enclosure`,
  `:icon`, or `:logo` for `role`.

  `mime_type` and `title` are optional strings. `width` and `height` are
  optional non-negative integers. Optional fields default to `nil`.
  """

  @type t :: %__MODULE__{
          url: String.t(),
          mime_type: String.t() | nil,
          kind: :image | :audio | :video | :unknown,
          role: :content | :thumbnail | :enclosure | :icon | :logo,
          title: String.t() | nil,
          width: non_neg_integer() | nil,
          height: non_neg_integer() | nil
        }

  @enforce_keys [:url, :kind, :role]
  defstruct url: nil,
            mime_type: nil,
            kind: nil,
            role: nil,
            title: nil,
            width: nil,
            height: nil
end
