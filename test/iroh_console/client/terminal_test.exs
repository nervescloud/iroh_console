defmodule IrohConsole.Client.TerminalTest do
  use ExUnit.Case, async: true

  alias IrohConsole.Client.Terminal

  describe "attach/2 without a controlling terminal" do
    test "refuses instead of proceeding with garbage termios settings" do
      # There is no /dev/tty under the test runner. The failure mode this guards
      # against is subtle: the shell's failed redirect prints an error that looks
      # like ordinary output, so a naive implementation reads
      # "/dev/tty: Device not configured" as the settings to restore later, puts
      # the (non-existent) terminal into raw mode, and carries on.
      client = spawn(fn -> Process.sleep(:infinity) end)

      assert Terminal.attach(client) == {:error, :not_a_terminal}
    end

    test "does not leave the io device in binary mode after refusing" do
      # attach/2 should bail before touching :io.setopts at all.
      client = spawn(fn -> Process.sleep(:infinity) end)
      assert {:error, :not_a_terminal} = Terminal.attach(client)
    end
  end
end
