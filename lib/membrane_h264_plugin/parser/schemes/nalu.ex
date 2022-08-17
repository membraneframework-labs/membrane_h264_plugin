defmodule Membrane.H264.Parser.Schemes.NALu do
  @moduledoc false
  alias Membrane.H264.Parser.NALuPayload
  alias Membrane.H264.Parser.Schemes

  @behaviour Membrane.H264.Parser.Scheme

  @impl true
  def scheme(),
    do: [
      field: {:forbidden_zero_bit, :u1},
      field: {:nal_ref_idc, :u2},
      field: {:nal_unit_type, :u5},
      execute: &parse_proper_nalu_type(&1, &2, &3)
    ]

  defp parse_proper_nalu_type(payload, state, _prefix) do
    case NALuPayload.nalu_types()[state.nal_unit_type] do
      :sps ->
        NALuPayload.parse_with_scheme(payload, Schemes.SPS.scheme(), state)

      :pps ->
        NALuPayload.parse_with_scheme(payload, Schemes.PPS.scheme(), state)

      :idr ->
        NALuPayload.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      :non_idr ->
        NALuPayload.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      _ ->
        {payload, state}
    end
  end
end
