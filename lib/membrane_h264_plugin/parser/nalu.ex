defmodule Membrane.H264.Parser.NALu do
  @moduledoc """
  A module defining a struct representing a single NAL unit.
  """
  use Bunch.Access
  @typedoc """
  A type defining the structure of a single NAL unit produced by the parser.
  """
  @type t :: %{
    parsed_fields: %{atom() => any()},
    prexifed_poslen: {integer(), integer()},
    type: atom(),
    unprefixed_poslen: {integer(), integer()}
  }

  @enforce_keys [:prefixed_poslen, :unprefixed_poslen]
  defstruct @enforce_keys ++ [:type, :parsed_fields]
end
