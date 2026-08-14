defmodule IrohConsole.FrameTest do
  use ExUnit.Case, async: true

  alias IrohConsole.Frame

  defp roundtrip(frame) do
    {:ok, decoded, rest} = frame |> Frame.encode!() |> IO.iodata_to_binary() |> Frame.decode()
    assert rest == ""
    decoded
  end

  describe "round trip" do
    test "carries every frame type unchanged" do
      for frame <- [
            {:data, "iex(1)> "},
            {:data, <<0, 255, 27, 91, 51, 51, 109>>},
            {:data, ""},
            {:resize, 80, 24},
            {:resize, 0, 0},
            {:resize, 65535, 65535},
            {:challenge, :crypto.strong_rand_bytes(32)},
            {:response, :crypto.strong_rand_bytes(64)},
            :ready,
            {:error_message, "not authorised"}
          ] do
        assert roundtrip(frame) == frame
      end
    end

    test "preserves utf-8 payloads byte for byte" do
      assert roundtrip({:data, "héllo → 世界"}) == {:data, "héllo → 世界"}
    end
  end

  describe "decode/1 with partial input" do
    test "asks for more when the header is incomplete" do
      for n <- 0..4 do
        assert Frame.decode(:binary.part(encoded({:data, "hi"}), 0, n)) == :more
      end
    end

    test "asks for more when the payload is incomplete" do
      full = encoded({:data, "hello world"})
      assert Frame.decode(:binary.part(full, 0, byte_size(full) - 1)) == :more
    end

    test "returns the unconsumed remainder" do
      buffer = encoded({:data, "one"}) <> encoded({:resize, 80, 24})
      assert {:ok, {:data, "one"}, rest} = Frame.decode(buffer)
      assert {:ok, {:resize, 80, 24}, ""} = Frame.decode(rest)
    end
  end

  describe "decode/1 with hostile input" do
    test "rejects an implausible length without waiting for the bytes" do
      # The peer claims 4 GiB. We must reject immediately rather than buffer.
      assert {:error, {:frame_too_large, _}} = Frame.decode(<<0x01, 0xFFFFFFFF::32>>)
    end

    test "rejects a length one byte over the limit" do
      over = Frame.max_payload() + 1
      assert {:error, {:frame_too_large, ^over}} = Frame.decode(<<0x01, over::32>>)
    end

    test "rejects unknown tags" do
      assert {:error, {:unknown_tag, 0x7F}} = Frame.decode(<<0x7F, 0::32>>)
    end

    test "rejects a resize with the wrong payload size" do
      assert {:error, :malformed_resize} = Frame.decode(<<0x02, 3::32, 1, 2, 3>>)
    end

    test "rejects a ready frame carrying a payload" do
      assert {:error, :malformed_ready} = Frame.decode(<<0x05, 2::32, "hi">>)
    end

    test "never raises on arbitrary bytes" do
      for _ <- 1..200 do
        bytes = :crypto.strong_rand_bytes(:rand.uniform(64))

        assert Frame.decode(bytes) in [:more] or
                 match?({:ok, _, _}, Frame.decode(bytes)) or
                 match?({:error, _}, Frame.decode(bytes))
      end
    end
  end

  describe "decode_all/1" do
    test "drains complete frames and keeps the tail" do
      buffer =
        encoded({:data, "a"}) <>
          encoded({:resize, 100, 40}) <>
          encoded(:ready) <>
          :binary.part(encoded({:data, "partial"}), 0, 4)

      assert {:ok, frames, rest} = Frame.decode_all(buffer)
      assert frames == [{:data, "a"}, {:resize, 100, 40}, :ready]
      assert byte_size(rest) == 4
    end

    test "returns empty for an empty buffer" do
      assert {:ok, [], ""} = Frame.decode_all("")
    end

    test "fails the whole buffer when any frame is malformed" do
      buffer = encoded({:data, "fine"}) <> <<0x7F, 0::32>>
      assert {:error, {:unknown_tag, 0x7F}} = Frame.decode_all(buffer)
    end
  end

  describe "encode!/1 limits" do
    test "accepts a payload exactly at the limit" do
      payload = :binary.copy("x", Frame.max_payload())
      assert roundtrip({:data, payload}) == {:data, payload}
    end

    test "raises above the limit rather than emitting an unreadable frame" do
      payload = :binary.copy("x", Frame.max_payload() + 1)

      assert_raise ArgumentError, ~r/exceeds the/, fn ->
        Frame.encode!({:data, payload})
      end
    end
  end

  defp encoded(frame), do: frame |> Frame.encode!() |> IO.iodata_to_binary()
end
