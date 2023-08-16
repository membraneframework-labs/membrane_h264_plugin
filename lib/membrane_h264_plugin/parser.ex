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
  for rewriting of timestamps:
  * in the `:bytestream` mode:
    * if option `:framerate` is set to nil, the output buffers have their `:pts` and `:dts` set to nil
    * if framerate is specified, `:pts` and `:dts` will be generated automatically, based on that framerate, starting from 0
     This may only be used with h264 profiles `:baseline` and `:constrained_baseline`, where `PTS==DTS`.
  * in the `:nalu_aligned` mode, the output buffers have their `:pts` and `:dts` set to `:pts` and `:dts` of the
   input buffer that was holding the first NAL unit making up given access unit (that is being sent inside that output buffer).
  * in the `:au_aligned` mode, the output buffers have their `:pts` and `:dts` set to `:pts` and `:dts` of the input buffer
  (holding the whole access unit being output)

  """

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{Buffer, H264, RemoteStream}

  alias Membrane.H264.Parser.{
    AUSplitter,
    AUTimestampGenerator,
    DecoderConfigurationRecord,
    Format,
    NALuParser,
    NALuSplitter
  }

  @prefix_code <<0, 0, 0, 1>>

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    accepted_format:
      any_of(
        %RemoteStream{type: :bytestream},
        %H264{alignment: alignment} when alignment in [:nalu, :au],
        %H264.RemoteStream{alignment: alignment} when alignment in [:nalu, :au]
      )

  def_output_pad :output,
    demand_mode: :auto,
    accepted_format:
      %H264{alignment: alignment, nalu_in_metadata?: true} when alignment in [:nalu, :au]

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
              output_alignment: [
                spec: :au | :nalu,
                default: :au,
                description: """
                Alignment of the buffers produced as an output of the parser.
                If set to `:au`, each output buffer will be a single access unit.
                Otherwise, if set to `:nalu`, each output buffer will be a single NAL unit.
                Defaults to `:au`.
                """
              ],
              skip_until_keyframe: [
                spec: boolean(),
                default: true,
                description: """
                Determines whether to drop the stream until the first key frame is received.

                Defaults to false.
                """
              ],
              repeat_parameter_sets: [
                spec: boolean(),
                default: false,
                description: """
                Repeat all parameter sets (`sps` and `pps`) on each IDR picture.

                Parameter sets may be retrieved from:
                  * The bytestream
                  * `Parser` options.
                  * Decoder Configuration Record, sent as decoder_configuration_record
                  in `Membrane.H264.RemoteStream` stream format
                """
              ],
              generate_best_effort_timestamps: [
                spec:
                  false
                  | %{
                      :framerate => {pos_integer, pos_integer},
                      optional(:add_dts_offset) => boolean
                    },
                default: false,
                description: """
                Generates timestamps based on given `framerate`.

                This option works only when `Membrane.RemoteStream` format arrives.

                Keep in mind that the generated timestamps may be inaccurate and lead
                to video getting out of sync with other media, therefore h264 should
                be kept in a container that stores the timestamps alongside.

                By default, the parser adds negative DTS offset to the timestamps,
                so that in case of frame reorder (which always happens when B frames
                are present) the DTS was always bigger than PTS. If that is not desired,
                you can set `add_dts_offset: false`.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    {sps, opts} = Map.pop!(opts, :sps)
    {pps, opts} = Map.pop!(opts, :pps)
    {ts_generation_config, opts} = Map.pop!(opts, :generate_best_effort_timestamps)

    au_timestamp_generator =
      if ts_generation_config, do: AUTimestampGenerator.new(ts_generation_config), else: nil

    state =
      %{
        nalu_splitter: NALuSplitter.new(maybe_add_prefix(sps) <> maybe_add_prefix(pps)),
        nalu_parser: NALuParser.new(),
        au_splitter: AUSplitter.new(),
        au_timestamp_generator: au_timestamp_generator,
        mode: nil,
        profile: nil,
        previous_buffer_timestamps: nil,
        frame_prefix: <<>>,
        parameter_sets_present?: byte_size(sps) > 0 or byte_size(pps) > 0,
        cached_sps: %{},
        cached_pps: %{}
      }
      |> Map.merge(Map.from_struct(opts))

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    state =
      case stream_format do
        %H264{alignment: alignment} ->
          mode =
            case alignment do
              :nalu -> :nalu_aligned
              :au -> :au_aligned
            end

          %{state | mode: mode}

        %RemoteStream{type: :bytestream} ->
          %{state | mode: :bytestream}

        %H264.RemoteStream{alignment: alignment, decoder_configuration_record: dcr} ->
          mode =
            case alignment do
              :nalu -> :nalu_aligned
              :au -> :au_aligned
            end

          %{state | mode: mode, frame_prefix: get_frame_prefix!(dcr, state)}
      end

    {[], state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    {payload, state} =
      case state.frame_prefix do
        <<>> -> {buffer.payload, state}
        prefix -> {prefix <> buffer.payload, %{state | frame_prefix: <<>>}}
      end

    is_nalu_aligned = state.mode != :bytestream

    {nalus_payloads, nalu_splitter} =
      NALuSplitter.split(payload, is_nalu_aligned, state.nalu_splitter)

    timestamps = if state.mode == :bytestream, do: {nil, nil}, else: {buffer.pts, buffer.dts}
    {nalus, nalu_parser} = NALuParser.parse_nalus(nalus_payloads, timestamps, state.nalu_parser)
    is_au_aligned = state.mode == :au_aligned
    {access_units, au_splitter} = AUSplitter.split(nalus, is_au_aligned, state.au_splitter)
    {access_units, state} = skip_improper_aus(access_units, state)
    {actions, state} = prepare_actions_for_aus(access_units, state)

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
    {last_nalu_payload, nalu_splitter} = NALuSplitter.split(<<>>, true, state.nalu_splitter)
    {last_nalu, nalu_parser} = NALuParser.parse_nalus(last_nalu_payload, state.nalu_parser)
    {maybe_improper_aus, au_splitter} = AUSplitter.split(last_nalu, true, state.au_splitter)
    {aus, state} = skip_improper_aus(maybe_improper_aus, state)
    {actions, state} = prepare_actions_for_aus(aus, state)

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

  defp maybe_add_prefix(parameter_set) do
    case parameter_set do
      <<>> -> <<>>
      <<0, 0, 1, _rest::binary>> -> parameter_set
      <<0, 0, 0, 1, _rest::binary>> -> parameter_set
      parameter_set -> @prefix_code <> parameter_set
    end
  end

  defp skip_improper_aus(aus, state) do
    Enum.flat_map_reduce(aus, state, fn au, state ->
      has_seen_keyframe? =
        Enum.all?(au, &(&1.status == :valid)) and Enum.any?(au, &(&1.type == :idr))

      state = %{
        state
        | skip_until_keyframe: state.skip_until_keyframe and not has_seen_keyframe?
      }

      if Enum.any?(au, &(&1.status == :error)) or state.skip_until_keyframe do
        {[], state}
      else
        {[au], state}
      end
    end)
  end

  defp prepare_actions_for_aus(aus, state) do
    Enum.flat_map_reduce(aus, state, fn au, state ->
      {sps_actions, state} = maybe_parse_sps(au, state)

      au = maybe_add_parameter_sets(au, state) |> delete_duplicate_parameter_sets()
      state = cache_parameter_sets(state, au)

      {{pts, dts}, state} = prepare_timestamps(au, state)

      buffers_actions = [
        {:buffer, {:output, wrap_into_buffer(au, pts, dts, state.output_alignment)}}
      ]

      {sps_actions ++ buffers_actions, state}
    end)
  end

  defp maybe_parse_sps(au, state) do
    case Enum.find(au, &(&1.type == :sps)) do
      nil ->
        {[], state}

      sps_nalu ->
        fmt = Format.from_sps(sps_nalu, output_alignment: state.output_alignment)
        {[stream_format: {:output, fmt}], %{state | profile: fmt.profile}}
    end
  end

  defp prepare_timestamps(au, state) do
    if state.mode == :bytestream and state.au_timestamp_generator do
      {timestamps, timestamp_generator} =
        AUTimestampGenerator.generate_ts_with_constant_framerate(
          au,
          state.au_timestamp_generator
        )

      {timestamps, %{state | au_timestamp_generator: timestamp_generator}}
    else
      {hd(au).timestamps, state}
    end
  end

  defp maybe_add_parameter_sets(au, %{repeat_parameter_sets: false}), do: au

  defp maybe_add_parameter_sets(au, state) do
    if idr_au?(au),
      do: Map.values(state.cached_sps) ++ Map.values(state.cached_pps) ++ au,
      else: au
  end

  defp delete_duplicate_parameter_sets(au) do
    if idr_au?(au), do: Enum.uniq(au), else: au
  end

  defp cache_parameter_sets(%{repeat_parameter_sets: false} = state, _au), do: state

  defp cache_parameter_sets(state, au) do
    sps =
      Enum.filter(au, &(&1.type == :sps))
      |> Enum.map(&{&1.parsed_fields.seq_parameter_set_id, &1})
      |> Map.new()
      |> Map.merge(state.cached_sps)

    pps =
      Enum.filter(au, &(&1.type == :pps))
      |> Enum.map(&{&1.parsed_fields.pic_parameter_set_id, &1})
      |> Map.new()
      |> Map.merge(state.cached_pps)

    %{state | cached_sps: sps, cached_pps: pps}
  end

  defp idr_au?(au), do: :idr in Enum.map(au, & &1.type)

  defp wrap_into_buffer(access_unit, pts, dts, :au) do
    metadata = prepare_au_metadata(access_unit)

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

  defp wrap_into_buffer(access_unit, pts, dts, :nalu) do
    access_unit
    |> Enum.zip(prepare_nalus_metadata(access_unit))
    |> Enum.map(fn {nalu, metadata} ->
      %Buffer{payload: nalu.payload, metadata: metadata, pts: pts, dts: dts}
    end)
  end

  defp prepare_au_metadata(nalus) do
    is_keyframe? = Enum.any?(nalus, fn nalu -> nalu.type == :idr end)

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
            put_in(metadata, [:metadata, :h264, :new_access_unit], %{key_frame?: is_keyframe?})
          else
            metadata
          end

        {metadata, nalu_start + byte_size(nalu.payload)}
      end)
      |> elem(0)

    %{h264: %{key_frame?: is_keyframe?, nalus: nalus}}
  end

  defp prepare_nalus_metadata(nalus) do
    is_keyframe? = Enum.any?(nalus, fn nalu -> nalu.type == :idr end)

    Enum.with_index(nalus)
    |> Enum.map(fn {nalu, i} ->
      %{h264: %{type: nalu.type}}
      |> Bunch.then_if(
        i == 0,
        &put_in(&1, [:h264, :new_access_unit], %{key_frame?: is_keyframe?})
      )
      |> Bunch.then_if(i == length(nalus) - 1, &put_in(&1, [:h264, :end_access_unit], true))
    end)
  end

  defp stream_format_sent?(actions, %{pads: %{output: %{stream_format: nil}}}),
    do: Enum.any?(actions, &match?({:stream_format, _stream_format}, &1))

  defp stream_format_sent?(_actions, _ctx), do: true

  defp get_frame_prefix!(dcr, state) do
    cond do
      dcr == nil ->
        <<>>

      state.parameter_sets_present? ->
        raise "Parameter sets were already provided as the options to the parser and parameter sets from the decoder configuration record could overwrite them."

      true ->
        {:ok, %{sps: sps, pps: pps}} = DecoderConfigurationRecord.parse(dcr)
        Enum.concat([[<<>>], sps, pps]) |> Enum.join(@prefix_code)
    end
  end
end
