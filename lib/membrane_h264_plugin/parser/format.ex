defmodule Membrane.H264.Parser.Format do
  @moduledoc """
  Module providing functionalities for preparing H264
  format based on the parsed SPS NAL units.
  """

  alias Membrane.H264

  @default_format %H264{
    alignment: :au,
    framerate: nil,
    height: 720,
    nalu_in_metadata?: true,
    profile: :high,
    width: 1280
  }

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
    high_4_2_2_intra: [profile_idc: 122, constraint_set3: 1],
    high_4_2_2: [profile_idc: 122],
    high_4_4_4_intra: [profile_idc: 244, constraint_set3: 1],
    high_4_4_4_predictive: [profile_idc: 244]
  ]

  @doc """
  Prepares the `Membrane.H264.t()` format based on the parsed SPS NALu.
  During the process, the function determines the profile of
  the h264 stream and the picture resolution.
  """
  @spec from_sps(
          sps_nalu :: H264.Parser.NALu.t(),
          options_fields :: [framerate: {pos_integer(), pos_integer()}]
        ) :: H264.t()
  def from_sps(sps_nalu, options_fields) do
    sps = sps_nalu.parsed_fields

    chroma_array_type = if sps.separate_colour_plane_flag == 0, do: sps.chroma_format_idc, else: 0

    {sub_width_c, sub_height_c} =
      case sps.chroma_format_idc do
        1 -> {2, 2}
        2 -> {2, 1}
        3 -> {1, 1}
        _other -> {nil, nil}
      end

    {crop_unit_x, crop_unit_y} =
      if chroma_array_type == 0,
        do: {1, 2 - sps.frame_mbs_only_flag},
        else: {sub_width_c, sub_height_c * (2 - sps.frame_mbs_only_flag)}

    {width_offset, height_offset} =
      if sps.frame_cropping_flag == 1,
        do:
          {(sps.frame_crop_right_offset + sps.frame_crop_left_offset) * crop_unit_x,
           (sps.frame_crop_top_offset +
              sps.frame_crop_bottom_offset) * crop_unit_y},
        else: {0, 0}

    width_in_mbs = sps.pic_width_in_mbs_minus1 + 1
    width = width_in_mbs * 16 - width_offset

    height_in_map_units = sps.pic_height_in_map_units_minus1 + 1
    height_in_mbs = (2 - sps.frame_mbs_only_flag) * height_in_map_units
    height = height_in_mbs * 16 - height_offset

    profile = parse_profile(sps_nalu)

    %H264{
      @default_format
      | width: width,
        height: height,
        profile: profile,
        framerate: Keyword.get(options_fields, :framerate)
    }
  end

  defp parse_profile(sps_nalu) do
    fields = sps_nalu.parsed_fields

    {profile_name, _constraints_list} =
      Enum.find(@profiles_description, {nil, nil}, fn {_profile_name, constraints_list} ->
        Enum.all?(constraints_list, fn {key, value} ->
          Map.has_key?(fields, key) and fields[key] == value
        end)
      end)

    if profile_name == nil, do: raise("Cannot read the profile name based on SPS's fields.")
    profile_name
  end
end
