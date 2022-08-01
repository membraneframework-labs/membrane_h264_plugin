defmodule Membrane.H264.Parser.NALu do
  @moduledoc false

  # See https://yumichan.net/video-processing/video-compression/introduction-to-h264-nal-unit/
  @nalu_types %{
                0 => :unspecified,
                1 => :non_idr,
                2 => :part_a,
                3 => :part_b,
                4 => :part_c,
                5 => :idr,
                6 => :sei,
                7 => :sps,
                8 => :pps,
                9 => :aud,
                10 => :end_of_seq,
                11 => :end_of_stream,
                12 => :filler_data,
                13 => :sps_extension,
                14 => :prefix_nal_unit,
                15 => :subset_sps,
                (16..18) => :reserved,
                19 => :auxiliary_non_part,
                20 => :extension,
                (21..23) => :reserved,
                (24..31) => :unspecified
              }
              |> Enum.flat_map(fn
                {k, v} when is_integer(k) -> [{k, v}]
                {k, v} -> Enum.map(k, &{&1, v})
              end)
              |> Map.new()

  @spec parse(binary, boolean) :: [map]
  def parse(payload, all? \\ false) do
    payload
    |> extract_nalus
    |> then(fn x -> if all?, do: x, else: Enum.drop(x, -1) end)
    |> Enum.map(&parse_type(&1, payload))
  end

  defp extract_nalus(payload) do
    payload
    |> :binary.matches([<<0, 0, 0, 1>>, <<0, 0, 1>>])
    |> Enum.chunk_every(2, 1, [{byte_size(payload), nil}])
    |> Enum.map(fn [{from, prefix_len}, {to, _}] ->
      len = to - from
      %{prefixed_poslen: {from, len}, unprefixed_poslen: {from + prefix_len, len - prefix_len}}
    end)
  end

  defp parse_type(nalu, payload) do
    <<0::1, _nal_ref_idc::unsigned-integer-size(2), nal_unit_type::unsigned-integer-size(5),
      _rest::bitstring>> = :binary.part(payload, nalu.unprefixed_poslen)

    type = @nalu_types |> Map.fetch!(nal_unit_type)

    Map.put(nalu, :type, type)
  end
end
