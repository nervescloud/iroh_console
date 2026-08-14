defmodule IrohConsole.Frame do
  @moduledoc """
  Wire framing for a console session.

  The session carries more than keystrokes — terminal resizes and the auth
  challenge/response share the same stream — so the bytes cannot be raw
  terminal data. Every message is a tagged, length-prefixed frame:

      <<tag::8, length::32-big, payload::binary-size(length)>>

  ## Trust

  `encode!/1` is for frames we build ourselves, so an oversized payload is a
  bug here and raises. `decode/1` parses whatever the peer sent and must never
  raise or over-allocate: an implausible length is rejected on sight rather
  than buffered, so a peer cannot make us wait on 4 GiB that will never arrive.
  """

  # Comfortably above any terminal write, far below anything worth buffering.
  @max_payload 1024 * 1024

  @hello 0x00
  @data 0x01
  @resize 0x02
  @challenge 0x03
  @response 0x04
  @ready 0x05
  @error 0x06

  @type t ::
          {:hello, 0..255}
          | {:data, binary()}
          | {:resize, non_neg_integer(), non_neg_integer()}
          | {:challenge, binary()}
          | {:response, binary()}
          | :ready
          | {:error_message, binary()}

  @doc """
  The protocol version a client announces in its `:hello`.

  A stream is not signalled to the far side until the opener writes, so the
  client has to speak first regardless — which makes the first frame the natural
  place to state a version.
  """
  @spec protocol_version() :: 0..255
  def protocol_version, do: 1

  @doc "Largest payload a single frame may carry. Callers chunk to this."
  @spec max_payload() :: pos_integer()
  def max_payload, do: @max_payload

  @doc """
  Encodes a frame.

  Raises when the payload exceeds `max_payload/0`, because that can only be a
  bug on this side — chunk before calling.
  """
  @spec encode!(t()) :: iodata()
  def encode!({:hello, version}) when is_integer(version) and version in 0..255,
    do: build!(@hello, <<version::8>>)

  def encode!({:data, payload}) when is_binary(payload), do: build!(@data, payload)
  def encode!({:challenge, nonce}) when is_binary(nonce), do: build!(@challenge, nonce)
  def encode!({:response, proof}) when is_binary(proof), do: build!(@response, proof)
  def encode!({:error_message, msg}) when is_binary(msg), do: build!(@error, msg)
  def encode!(:ready), do: build!(@ready, <<>>)

  def encode!({:resize, width, height})
      when is_integer(width) and width in 0..0xFFFF and
             is_integer(height) and height in 0..0xFFFF do
    build!(@resize, <<width::16, height::16>>)
  end

  defp build!(tag, payload) when byte_size(payload) <= @max_payload do
    [<<tag::8, byte_size(payload)::32>>, payload]
  end

  defp build!(_tag, payload) do
    raise ArgumentError,
          "frame payload of #{byte_size(payload)} bytes exceeds the #{@max_payload} byte limit; " <>
            "chunk to IrohConsole.Frame.max_payload/0 before encoding"
  end

  @doc """
  Pulls one frame off the front of `buffer`.

  Returns `:more` when the buffer holds only part of a frame, so the caller can
  read again and retry with the accumulated bytes.
  """
  @spec decode(binary()) :: {:ok, t(), binary()} | :more | {:error, term()}
  def decode(<<_tag::8, length::32, _rest::binary>>) when length > @max_payload do
    {:error, {:frame_too_large, length}}
  end

  def decode(<<tag::8, length::32, payload::binary-size(length), rest::binary>>) do
    with {:ok, frame} <- decode_payload(tag, payload) do
      {:ok, frame, rest}
    end
  end

  def decode(buffer) when is_binary(buffer), do: :more

  @doc """
  Drains every complete frame from `buffer`, returning the leftover bytes.

  A malformed frame fails the whole call: the stream position is no longer
  trustworthy once a frame cannot be parsed, so the session must be torn down
  rather than resynchronised.
  """
  @spec decode_all(binary()) :: {:ok, [t()], binary()} | {:error, term()}
  def decode_all(buffer) when is_binary(buffer), do: decode_all(buffer, [])

  defp decode_all(buffer, acc) do
    case decode(buffer) do
      {:ok, frame, rest} -> decode_all(rest, [frame | acc])
      :more -> {:ok, Enum.reverse(acc), buffer}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_payload(@hello, <<version::8>>), do: {:ok, {:hello, version}}
  defp decode_payload(@hello, _payload), do: {:error, :malformed_hello}
  defp decode_payload(@data, payload), do: {:ok, {:data, payload}}
  defp decode_payload(@challenge, payload), do: {:ok, {:challenge, payload}}
  defp decode_payload(@response, payload), do: {:ok, {:response, payload}}
  defp decode_payload(@error, payload), do: {:ok, {:error_message, payload}}
  defp decode_payload(@ready, <<>>), do: {:ok, :ready}
  defp decode_payload(@ready, _payload), do: {:error, :malformed_ready}
  defp decode_payload(@resize, <<width::16, height::16>>), do: {:ok, {:resize, width, height}}
  defp decode_payload(@resize, _payload), do: {:error, :malformed_resize}
  defp decode_payload(tag, _payload), do: {:error, {:unknown_tag, tag}}
end
