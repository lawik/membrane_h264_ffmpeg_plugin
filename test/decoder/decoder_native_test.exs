defmodule Decoder.NativeTest do
  use ExUnit.Case, async: true
  alias Membrane.H264.FFmpeg.Decoder.Native
  alias Membrane.Payload

  test "Decode 1 240p frame" do
    in_path = "../fixtures/input-100-240p.h264" |> Path.expand(__DIR__)
    ref_path = "../fixtures/reference-100-240p.raw" |> Path.expand(__DIR__)

    assert {:ok, file} = File.read(in_path)
    assert {:ok, decoder_ref} = Native.create()
    assert <<frame::bytes-size(7469), _rest::binary>> = file
    assert {:ok, _pts_list, _frames} = Native.decode(frame, 0, 0, false, decoder_ref)
    assert {:ok, _pts_list, [frame]} = Native.flush(false, decoder_ref)
    assert Payload.size(frame) == 115_200
    assert {:ok, ref_file} = File.read(ref_path)
    assert <<ref_frame::bytes-size(115_200), _rest::binary>> = ref_file
    assert Payload.to_binary(frame) == ref_frame
  end

  test "Frames are output in their own pixel format after a mid-stream SPS change" do
    # A 720p I420 stream with B-frames followed by a 360p I422 stream: the
    # decoder still holds reorder-delayed I420 frames when it switches to the
    # new SPS, and those must not be sized or copied as I422.
    i420_path = "../fixtures/input-10-720p.h264" |> Path.expand(__DIR__)
    i422_path = "../fixtures/input-20-360p-I422.h264" |> Path.expand(__DIR__)

    assert {:ok, i420} = File.read(i420_path)
    assert {:ok, i422} = File.read(i422_path)
    assert {:ok, decoder_ref} = Native.create()

    frames =
      Enum.flat_map(split_access_units(i420 <> i422), fn au ->
        assert {:ok, _pts_list, frames} = Native.decode(au, 0, 0, false, decoder_ref)
        frames
      end)

    assert {:ok, _pts_list, flushed} = Native.flush(false, decoder_ref)
    frames = frames ++ flushed

    assert length(frames) == 30

    sizes = Enum.map(frames, &Payload.size/1)
    i420_720p_size = div(1280 * 720 * 3, 2)
    i422_360p_size = 480 * 360 * 2
    assert Enum.count(sizes, &(&1 == i420_720p_size)) == 10
    assert Enum.count(sizes, &(&1 == i422_360p_size)) == 20
  end

  # Groups NAL units into access units, assuming one slice per picture: each
  # VCL NAL unit closes the access unit it belongs to.
  defp split_access_units(stream) do
    stream
    |> :binary.split([<<0, 0, 0, 1>>, <<0, 0, 1>>], [:global, :trim_all])
    |> Enum.chunk_while(
      <<>>,
      fn <<_f::1, _nri::2, type::5, _rest::binary>> = nalu, acc ->
        acc = acc <> <<0, 0, 0, 1>> <> nalu
        if type in [1, 5], do: {:cont, acc, <<>>}, else: {:cont, acc}
      end,
      fn
        <<>> -> {:cont, <<>>}
        acc -> {:cont, acc, <<>>}
      end
    )
  end
end
