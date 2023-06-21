defmodule AUSplitterTest do
  @moduledoc false

  use ExUnit.Case

  @test_files_names ["10-720a", "10-720p"]

  # These values were obtained with the use of H264.FFmpeg.Parser, available
  # in the membrane_h264_ffmpeg_plugin repository.
  @au_lengths_ffmpeg %{
    "10-720a" => [777, 146, 93, 136],
    "10-720p" => [25_699, 19_043, 14_379, 14_281, 14_761, 18_702, 14_735, 13_602, 12_094, 17_228]
  }

  defmodule FullBinaryParser do
    @moduledoc false
    alias Membrane.H264.Parser.{
      AUSplitter,
      NALuParser,
      NALuSplitter
    }

    @spec parse(binary()) :: AUSplitter.access_unit_t()
    def parse(payload) do
      nalu_splitter = NALuSplitter.new()
      {nalus_payloads, nalu_splitter} = NALuSplitter.split(payload, nalu_splitter)
      {last_nalu_payload, _nalu_splitter} = NALuSplitter.flush(nalu_splitter)
      nalus_payloads = nalus_payloads ++ [last_nalu_payload]

      nalu_parser = NALuParser.new()

      {nalus, _nalu_parser} =
        Enum.map_reduce(nalus_payloads, nalu_parser, &NALuParser.parse(&1, &2))

      {aus, au_splitter} = AUSplitter.split(nalus, AUSplitter.new())
      {last_au, _au_splitter} = AUSplitter.flush(au_splitter)
      aus ++ [last_au]
    end
  end

  test "if the access unit lenghts parsed by access unit splitter are the same as access units lengths parsed by FFMPEG" do
    for name <- @test_files_names do
      full_name = "test/fixtures/input-#{name}.h264"
      binary = File.read!(full_name)

      aus = FullBinaryParser.parse(binary)

      au_lengths =
        for au <- aus,
            do:
              Enum.reduce(au, 0, fn %{payload: payload}, acc ->
                byte_size(payload) + acc
              end)

      assert au_lengths == @au_lengths_ffmpeg[name]
    end
  end

  test "IDR frame split into two NALus" do
    # first frame of output of MP4 depayloader from Big Buck Bunny trailer
    fixture =
      <<0, 0, 0, 1, 39, 66, 224, 21, 169, 24, 60, 17, 253, 96, 13, 65, 128, 65, 173, 183, 160, 15,
        72, 15, 85, 239, 124, 4, 0, 0, 0, 1, 40, 222, 9, 136, 0, 0, 0, 1, 6, 0, 7, 131, 97, 235,
        0, 0, 3, 0, 64, 128, 0, 0, 0, 1, 6, 5, 17, 3, 135, 244, 78, 205, 10, 75, 220, 161, 148,
        58, 195, 212, 155, 23, 31, 3, 128, 0, 0, 0, 1, 37, 184, 32, 32, 255, 255, 252, 61, 20, 0,
        4, 21, 189, 247, 223, 125, 247, 223, 125, 247, 223, 125, 247, 223, 125, 247, 223, 125,
        247, 223, 125, 247, 223, 125, 245, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117,
        215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215,
        93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93,
        117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117,
        215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215,
        93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93,
        117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117,
        215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215,
        93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93,
        117, 215, 93, 117, 224, 0, 0, 0, 1, 37, 0, 128, 56, 32, 32, 255, 255, 252, 61, 20, 0, 4,
        21, 189, 247, 223, 125, 247, 223, 125, 247, 223, 125, 247, 255, 255, 240, 244, 80, 0, 16,
        86, 247, 223, 125, 247, 223, 125, 247, 223, 125, 247, 223, 93, 117, 215, 93, 117, 215, 93,
        117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117,
        215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215,
        93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93,
        117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117,
        215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215,
        93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93,
        117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117,
        215, 93, 117, 215, 93, 117, 255, 252, 126, 8, 2, 152, 28, 64, 32, 172, 183, 223, 125, 247,
        223, 125, 247, 223, 125, 247, 223, 125, 247, 223, 125, 247, 223, 125, 247, 223, 125, 247,
        224>>

    assert [au] = FullBinaryParser.parse(fixture)
    assert au |> Enum.map(&byte_size(&1.payload)) |> Enum.sum() == byte_size(fixture)
  end
end
