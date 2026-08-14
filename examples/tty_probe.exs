# Shows exactly what this terminal delivers to the BEAM, with no console or
# network involved. Answers three questions the io options cannot:
#
#   1. Does the terminal echo locally?   If your typing appears before any
#      "recv" line, something other than this script is printing it.
#   2. Line buffered, or per keystroke?  "recv" per character as you type means
#      per keystroke; a burst only after Enter means line buffered.
#   3. What is Enter?                    <<13>> is CR, so raw mode.
#                                        <<10>> is LF, so the line discipline
#                                        translated it, meaning cooked mode.
#
# Run it both ways and compare:
#
#   mix run examples/tty_probe.exs
#   stty raw -echo; mix run examples/tty_probe.exs; stty sane
#
# Type   abc   then Enter. Press Ctrl-] to stop.

defmodule TTYProbe do
  @escape <<0x1D>>

  def run do
    IO.puts("before setopts: #{inspect(:io.getopts(:standard_io))}")
    :io.setopts(:standard_io, binary: true, echo: false)
    IO.puts("after setopts:  #{inspect(:io.getopts(:standard_io))}")

    IO.write("\r\nType `abc` then Enter. Ctrl-] to stop.\r\n\r\n")
    loop(0)
  end

  defp loop(count) do
    case IO.binread(:stdio, 1) do
      :eof ->
        IO.write("\r\n-- eof after #{count} bytes --\r\n")

      {:error, reason} ->
        IO.write("\r\n-- error #{inspect(reason)} --\r\n")

      @escape ->
        IO.write("\r\n-- escape, #{count} bytes read --\r\n")

      data ->
        # Elapsed time matters as much as the byte: several arriving in the same
        # millisecond means they were buffered and released together.
        IO.write("recv #{inspect(data)} at #{System.monotonic_time(:millisecond)}\r\n")
        loop(count + 1)
    end
  end
end

TTYProbe.run()
