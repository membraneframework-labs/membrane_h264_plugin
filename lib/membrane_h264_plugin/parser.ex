defmodule Membrane.H264.Parser do
  @moduledoc false

  use Membrane.Filter

  require Membrane.Logger

  alias __MODULE__
  alias Membrane.{Buffer, H264}
  alias Membrane.H264.AccessUnitSplitter

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    caps: :any

  def_output_pad :output,
    demand_mode: :auto,
    caps: {H264, stream_format: :byte_stream}

  def_options alignment: [
                type: :atom,
                spec: :au | :nal,
                default: :au,
                description: """
                Stream units carried by each output buffer. See `t:Membrane.H264.alignment_t`.

                Only `:au` alignment is supported at the moment.
                """
              ],
              caps: [
                default: %H264{
                  alignment: :au,
                  framerate: {0, 1},
                  height: 720,
                  nalu_in_metadata?: false,
                  profile: :high,
                  stream_format: :byte_stream,
                  width: 1280
                },
                description: """
                For development only.
                """
              ],
              sps: [
                type: :binary,
                default: <<>>,
                description: """
                Sequence Parameter Set NAL unit - if absent in the stream, should
                be provided via this option.
                """
              ],
              pps: [
                type: :binary,
                default: <<>>,
                description: """
                Picture Parameter Set NAL unit - if absent in the stream, should
                be provided via this option.
                """
              ]

  @impl true
  def handle_init(opts) do
    if opts.alignment != :au do
      raise("Invalid element options, only `:au` alignment is available")
    end

    state = %{
      caps: opts.caps,
      metadata: %{},
      unparsed_payload: <<>>,
      splitter_buffer: [],
      splitter_state: :first,
      previous_primary_coded_picture_nalu: nil,
      parser_state: %Membrane.H264.Parser.State{__global__: %{}, __local__: %{}}
    }

    {:ok, state}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    # {{:ok, caps: {:output, state.caps}}, state}
    {:ok, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    process(state.unparsed_payload <> buffer.payload, [], state)
  end

  @impl true

  def handle_end_of_stream(:input, _ctx, %{unparsed_payload: payload} = state) do
    # process(payload, [end_of_stream: :output], state)
    {{:ok, buffer: {:output, %Buffer{payload: payload}}, end_of_stream: :output}, state}
  end

  defp process(payload, actions, state) do
    {nalus, parser_state} = Parser.NALu.parse(payload, state.parser_state)

    {_rest_of_nalus, splitter_buffer, splitter_state, previous_primary_coded_picture_nalu,
     access_units} = AccessUnitSplitter.split_nalus_into_access_units(nalus)

    unparsed_payload =
      splitter_buffer
      |> then(&parsed_poslen/1)
      |> then(fn {start, len} -> :binary.part(payload, start, len) end)

    state = %{
      state
      | splitter_buffer: splitter_buffer,
        parser_state: parser_state,
        splitter_state: splitter_state,
        previous_primary_coded_picture_nalu: previous_primary_coded_picture_nalu,
        unparsed_payload: unparsed_payload
    }

    if access_units == [] do
      {{:ok, actions}, state}
    else
      nalus = Enum.flat_map(access_units, & &1)

      # FIXME: don't pass hardcoded empty metadata
      sps_nalu = Enum.find(nalus, nil, fn nalu -> nalu.type == :sps end)
      profile = if sps_nalu != nil, do: get_profile(sps_nalu)
      buffers = Enum.map(access_units, &wrap_into_buffer(&1, payload, state.metadata))
      new_actions = [{:buffer, {:output, buffers}} | actions]

      new_actions =
        if profile != nil,
          do:
            [
              caps:
                {:output,
                 %H264{
                   alignment: :au,
                   framerate: {0, 1},
                   height: 720,
                   nalu_in_metadata?: false,
                   profile: profile,
                   stream_format: :byte_stream,
                   width: 1280
                 }}
            ] ++ new_actions,
          else: new_actions

      {{:ok, new_actions}, state}
    end
  end

  defp wrap_into_buffer(access_unit, payload, metadata) do
    access_unit
    |> then(&parsed_poslen/1)
    |> then(fn {start, len} -> :binary.part(payload, start, len) end)
    |> then(fn payload ->
      %Buffer{payload: payload, metadata: metadata}
    end)
  end

  defp parsed_poslen([]), do: {0, 0}

  defp parsed_poslen(parsed) do
    {start, _len} =
      parsed
      |> hd()
      |> get_in([:prefixed_poslen])

    len =
      parsed
      |> List.last()
      |> get_in([:unprefixed_poslen])
      |> then(fn {last_start, last_len} -> last_start + last_len - start end)

    {start, len}
  end

  @profiles_description [
    high_cavlc_4_4_4_intra: [profile_idc: 44],
    constrained_baseline: [profile_idc: 66, constraint_set1: 1],
    baseline: [profile_idc: 66],
    main: [profile_idc: 77],
    extended: [profile_idc: 88],
    constrained_high: [profile_idc: 100, constraint_set4: 1, constraint_set5: 1],
    progressive_high: [profile_idc: 100, constraint_set4: 1],
    high: [profile_idc: 100],
    high_10_intra: [profile_idc: 110, constraint_set3: 1],
    high_10: [profile_idc: 110],
    hight_4_2_2_intra: [profile_idc: 122, constraint_set3: 1],
    high_4_2_2: [profile_idc: 122],
    high_4_4_4_intra: [profile_idc: 244, constraint_set3: 1],
    high_4_4_4_predictive: [profile_idc: 244]
  ]

  defp get_profile(sps_nalu) do
    fields = sps_nalu.parsed_fields

    {profile_name, _constraints_list} =
      @profiles_description
      |> Enum.find({nil, nil}, fn {_profile_name, constraints_list} ->
        constraints_list
        |> Enum.all?(fn {key, value} ->
          Map.has_key?(fields, key) and fields[key] == value
        end)
      end)

    if profile_name == nil, do: raise("Cannot read the profile name based on SPS's fields.")
    profile_name
  end
end
