defmodule Membrane.H264.Common do
  @moduledoc """
  A module providing functions which are commonly used by different modules of the project.
  """
  use Ratio
  @h264_time_base 90_000

  @doc """
  Converts time in membrane time base (1 [ns]) to h264 time base (1/90_000 [s])
  """
  @spec to_h264_time_base_truncated(number | Ratio.t()) :: integer
  def to_h264_time_base_truncated(timestamp) do
    (timestamp * @h264_time_base / Membrane.Time.second()) |> Ratio.trunc()
  end

  @doc """
  Converts time from h264 time base (1/90_000 [s]) to membrane time base (1 [ns])
  """
  @spec to_membrane_time_base_truncated(number | Ratio.t()) :: integer
  def to_membrane_time_base_truncated(timestamp) do
    (timestamp * Membrane.Time.second() / @h264_time_base) |> Ratio.trunc()
  end

  @spec to_integer(bitstring(), keyword()) :: {integer(), bitstring()}
  @doc """
  Reads the appropriate number of bits from the bitstring and decodes an integer out of these bits.any()
  Returns the decoded integer and the rest of the bitstring, which wasn't used for decoding.
  By default, the decoded integer is an unsigned integer. If `negatives: true` is passed as an option, the decoded integer will be a signed integer.
  """
  def to_integer(binary, opts \\ [negatives: false])

  def to_integer(binary, negatives: should_support_negatives) do
    zeros_size = cut_zeros(binary)
    number_size = zeros_size + 1
    <<_zeros::size(zeros_size), number::size(number_size), rest::bitstring>> = binary
    number = number - 1

    if should_support_negatives do
      if rem(number, 2) == 0, do: -div(number, 2), else: div(number + 1, 2)
    else
      {number, rest}
    end
  end

  @spec to_exp_golomb(non_neg_integer()) :: bitstring()
  @doc """
  Returns a bitstring with an Exponential Golomb representation of an non negative integer.
  """
  def to_exp_golomb(integer) do
    # ceil(log(x)) can be calculated more accuratly and efficiently
    number_size = trunc(:math.floor(:math.log2(integer + 1))) + 1
    zeros_size = number_size - 1
    <<0::size(zeros_size), integer + 1::size(number_size)>>
  end

  defp cut_zeros(bitstring, how_many_zeros \\ 0) do
    <<x::1, rest::bitstring>> = bitstring

    case x do
      0 -> cut_zeros(rest, how_many_zeros + 1)
      1 -> how_many_zeros
    end
  end
end
