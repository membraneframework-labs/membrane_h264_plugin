defmodule Membrane.H264.Parser.NALu do
  @moduledoc """
  A module defining a struct representing a single NAL unit.
  """

  @typedoc """
  A type defining the structure of a single NAL unit produced
  by the parser.
  In the structure there are following fields:
  * `parsed_fields` - the map with keys being the NALu field names and the values being the value fetched from the NALu binary.
  They correspond to the NALu schemes defined in the section "7.3" of the "ITU-T Rec. H.264 (01/2012)".
  * `prefix_length` - number of bytes of the prefix used to split the NAL units in the bytestream.
  The prefix is defined as in: "Annex B" of the "ITU-T Rec. H.264 (01/2012)".
  * `type` - an atom representing the type of the NALu. Atom's name is based on the
  "Table 7-1 – NAL unit type codes, syntax element categories, and NAL unit type classes" of the "ITU-T Rec. H.264 (01/2012)".
  * `payload` - the binary, which parsing resulted in that structure being produced
  * `status` - `:valid`, if the parsing was successfull, `:error` otherwise
  """
  @type t :: %__MODULE__{
          parsed_fields: %{atom() => any()},
          prefix_length: pos_integer(),
          type: Membrane.H264.Parser.NALuTypes.nalu_type(),
          payload: binary(),
          status: :valid | :error
        }

  @enforce_keys [:parsed_fields, :prefix_length, :type, :payload, :status]
  defstruct @enforce_keys
end
