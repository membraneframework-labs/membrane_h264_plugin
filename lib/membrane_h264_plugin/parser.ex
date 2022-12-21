defmodule Membrane.H264.Parser do
  @moduledoc """
  Membrane element providing parser for H264 encoded video stream.

  The parser:
  * prepares and sends the appropriate stream format, based on information provided in the stream and via the element's options
  * splits the incoming stream into h264 access units - each buffer being output is a `Membrane.Buffer` struct with a
  binary payload of a single access unit
  * enriches the output buffers with the metadata describing the way the access unit is split into NAL units, type of each NAL unit
  making up the access unit and the information if the access unit hold a keyframe.

  The parser works in one of three possible modes, depending on the structure of the input buffers:
  * `:bytestream` - each input buffer contains some part of h264 stream's payload, but not necessary a logical
  h264 unit (like NAL unit or an access unit). Can be used for i.e. for parsing the stream read from the file.
  * `:nalu_aligned` - each input buffer contains a single NAL unit's payload
  * `:au_aligned` - each input buffer contains a single access unit's payload

  The parser's mode is set automatically, based on the input stream format received by that element:
  * Receiving `%Membrane.RemoteStream{type: :bytestream}` results in the parser mode being set to `:bytestream`
  * Receiving `%Membrane.H264.RemoteStream{alignment: :nalu}` results in the parser mode being set to `:nalu_aligned`
  * Receiving `%Membrane.H264.RemoteStream{alignment: :au}` results in the parser mode being set to `:au_aligned`

  The distinguishment between parser modes was introduced to eliminate the redundant operations and to provide a reliable way
  for timestamps rewritting:
  * in the `:bytestream` mode, the output buffers have their `:pts` and `:dts` set to nil
  * in the `:nalu_aligned` mode, the output buffers have their `:pts` and `:dts` set to `:pts` and `:dts` of the
   input buffer that was holding the first NAL unit making up given access unit (that is being sent inside that output buffer).
  * in the `:au_aligned` mode, the output buffers have their `:pts` and `:dts` set to `:pts` and `:dts` of the input buffer
  (holding the whole access unit being output)

  """

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{Buffer, H264, RemoteStream}
  alias Membrane.H264.Parser.{AUSplitter, Format, NALuParser, NALuSplitter}

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    accepted_format:
      any_of(
        %RemoteStream{type: :bytestream},
        %H264.RemoteStream{alignment: alignment} when alignment in [:nalu, :au]
      )

  def_output_pad :output,
    demand_mode: :auto,
    accepted_format: %H264{alignment: :au, nalu_in_metadata?: true}

  def_options sps: [
                spec: binary(),
                default: <<>>,
                description: """
                Sequence Parameter Set NAL unit binary payload - if absent in the stream, should
                be provided via this option.
                """
              ],
              pps: [
                spec: binary(),
                default: <<>>,
                description: """
                Picture Parameter Set NAL unit binary payload - if absent in the stream, should
                be provided via this option.
                """
              ],
              framerate: [
                spec: {pos_integer(), pos_integer()} | nil,
                default: nil,
                description: """
                Framerate of the video, represented as a tuple consisting of a numerator and the
                denominator.
                It's value will be sent inside the output Membrane.H264 caps.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      nalu_splitter: NALuSplitter.new(opts.sps <> opts.pps),
      nalu_parser: NALuParser.new(),
      au_splitter: AUSplitter.new(),
      mode: nil,
      previous_timestamps: {nil, nil},
      framerate: opts.framerate
    }

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    mode =
      case stream_format do
        %RemoteStream{type: :bytestream} -> :bytestream
        %H264.RemoteStream{alignment: :nalu} -> :nalu_aligned
        %H264.RemoteStream{alignment: :au} -> :au_aligned
      end

    state = %{state | mode: mode}
    {[], state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    {nalus_payloads_list, nalu_splitter} = NALuSplitter.split(buffer.payload, state.nalu_splitter)

    {nalus_payloads_list, nalu_splitter} =
      if state.mode != :bytestream do
        {last_nalu_payload, nalu_splitter} = NALuSplitter.flush(nalu_splitter)

        if last_nalu_payload != <<>> do
          {nalus_payloads_list ++ [last_nalu_payload], nalu_splitter}
        else
          {nalus_payloads_list, nalu_splitter}
        end
      else
        {nalus_payloads_list, nalu_splitter}
      end

    {nalus, nalu_parser} =
      Enum.map_reduce(nalus_payloads_list, state.nalu_parser, fn nalu_payload, nalu_parser ->
        NALuParser.parse(nalu_payload, nalu_parser)
      end)

    {access_units, au_splitter} =
      nalus
      |> Enum.filter(fn nalu -> nalu.status == :valid end)
      |> AUSplitter.split(state.au_splitter)

    {access_units, au_splitter} =
      if state.mode == :au_aligned do
        {last_au, au_splitter} = AUSplitter.flush(au_splitter)
        {access_units ++ [last_au], au_splitter}
      else
        {access_units, au_splitter}
      end

    {pts, dts} =
      case state.mode do
        :bytestream -> {nil, nil}
        :nalu_aligned -> state.previous_timestamps
        :au_aligned -> {buffer.pts, buffer.dts}
      end

    state =
      if state.mode == :nalu_aligned and state.previous_timestamps != {buffer.pts, buffer.dts} do
        %{state | previous_timestamps: {buffer.pts, buffer.dts}}
      else
        state
      end

    actions = prepare_actions_for_aus(access_units, pts, dts, state)

    state = %{
      state
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    {actions, state}
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) when state.mode != :au_aligned do
    {last_nalu_payload, nalu_splitter} = NALuSplitter.flush(state.nalu_splitter)

    {{access_units, au_splitter}, nalu_parser} =
      if last_nalu_payload != <<>> do
        {last_nalu, nalu_parser} = NALuParser.parse(last_nalu_payload, state.nalu_parser)

        if last_nalu.status == :valid do
          {AUSplitter.split([last_nalu], state.au_splitter), nalu_parser}
        else
          {{[], state.au_splitter}, nalu_parser}
        end
      else
        {{[], state.au_splitter}, state.nalu_parser}
      end

    {remaining_nalus, au_splitter} = AUSplitter.flush(au_splitter)
    maybe_improper_aus = access_units ++ [remaining_nalus]

    {pts, dts} =
      case state.mode do
        :bytestream -> {nil, nil}
        :nalu_aligned -> state.previous_timestamps
      end

    actions = prepare_actions_for_aus(maybe_improper_aus, pts, dts, state)
    actions = if stream_format_sent?(actions, ctx), do: actions, else: []

    state = %{
      state
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    {actions ++ [end_of_stream: :output], state}
  end

  @impl true
  def handle_end_of_stream(_pad, _ctx, state) do
    {[end_of_stream: :output], state}
  end

  defp prepare_actions_for_aus(aus, pts, dts, state) do
    Enum.reduce(aus, [], fn au, acc ->
      sps_actions =
        case Enum.find(au, &(&1.type == :sps)) do
          nil ->
            []

          sps_nalu ->
            [stream_format: {:output, Format.from_sps(sps_nalu, framerate: state.framerate)}]
        end

      acc ++ sps_actions ++ [{:buffer, {:output, wrap_into_buffer(au, pts, dts)}}]
    end)
  end

  defp wrap_into_buffer(access_unit, pts, dts) do
    metadata = prepare_metadata(access_unit)

    buffer =
      access_unit
      |> Enum.reduce(<<>>, fn nalu, acc ->
        acc <> nalu.payload
      end)
      |> then(fn payload ->
        %Buffer{payload: payload, metadata: metadata, pts: pts, dts: dts}
      end)

    buffer
  end

  defp prepare_metadata(nalus) do
    is_keyframe = Enum.any?(nalus, fn nalu -> nalu.type == :idr end)

    nalus =
      nalus
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {nalu, i}, nalu_start ->
        metadata = %{
          metadata: %{
            h264: %{
              type: nalu.type
            }
          },
          prefixed_poslen: {nalu_start, byte_size(nalu.payload)},
          unprefixed_poslen:
            {nalu_start + nalu.prefix_length, byte_size(nalu.payload) - nalu.prefix_length}
        }

        metadata =
          if i == length(nalus) - 1 do
            put_in(metadata, [:metadata, :h264, :end_access_unit], true)
          else
            metadata
          end

        metadata =
          if i == 0 do
            put_in(metadata, [:metadata, :h264, :new_access_unit], %{key_frame?: is_keyframe})
          else
            metadata
          end

        {metadata, nalu_start + byte_size(nalu.payload)}
      end)
      |> elem(0)

    %{h264: %{key_frame?: is_keyframe, nalus: nalus}}
  end

  defp stream_format_sent?(actions, %{pads: %{output: %{stream_format: nil}}}),
    do: Enum.any?(actions, &match?({:stream_format, _stream_format}, &1))

  defp stream_format_sent?(_actions, _ctx), do: true
end
