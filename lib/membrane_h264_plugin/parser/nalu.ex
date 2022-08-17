defmodule Membrane.H264.Parser.NALu do
  @moduledoc """
  A module with functions responsible for parsing of the binary stream and producing the NALu structures
  """
  alias Membrane.H264.Parser.NALuPayload
  alias Membrane.H264.Parser.Schemes

  @typedoc """
  A type defining the state of the parser. The parser preserves its state in the map, which consists of two parts:
  * a map under the `:__global__` key
  * user defined {key, value} pairs, which are put into the state during the parsing process.
  The user defined part of a state is valid during a time of a single NALu processing, and cleaned after the NALu is
  completly parsed.
  If some information needs to be available when other NALu is parsed, it needs to be stored in the map under the `:__global__` key of the parser's state.
  """
  @type state_t :: %{__global__: map()}

  @typedoc """
  A type defining the structure of a single NAL unit produced by the parser.
  """
  @type nalu_t :: %{
          parsed_fields: %{atom() => any()},
          prexifed_poslen: {integer(), integer()},
          type: atom(),
          unprefixed_poslen: {integer(), integer()}
        }

  @spec parse(binary(), state_t()) :: {list(nalu_t), state_t()}
  @doc """
  Parses the given binary stream, and produces the NAL units of the structurized form.
  """
  def parse(payload, state \\ %{__global__: %{}}) do
    {nalus, state} =
      payload
      |> extract_nalus
      |> Enum.map_reduce(state, fn nalu, state ->
        {nalu_start_in_bytes, nalu_size_in_bytes} = nalu.unprefixed_poslen
        nalu_start = nalu_start_in_bytes * 8

        <<_beggining::size(nalu_start), nalu_payload::binary-size(nalu_size_in_bytes),
          _rest::bitstring>> = payload

        {_rest_of_nalu_payload, state} =
          NALuPayload.parse_with_scheme(nalu_payload, Schemes.NALu.scheme(), state)

        state_without_global =
          state |> Enum.filter(fn {key, _value} -> key != :__global__ end) |> Map.new()

        new_state = %{__global__: state.__global__}
        {Map.put(nalu, :parsed_fields, state_without_global), new_state}
      end)

    nalus =
      nalus
      |> Enum.map(fn nalu ->
        Map.put(nalu, :type, NALuPayload.nalu_types()[nalu.parsed_fields.nal_unit_type])
      end)

    {nalus, state}
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
end
