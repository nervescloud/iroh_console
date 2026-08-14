# Proves the whole path: a device-side console and an operator-side client,
# both on a real relay, with a real TOTP handshake and a real IEx shell.
#
#   mix run examples/end_to_end.exs                                  # n0's relays
#   IROH_RELAY_URL=https://relay.example.com mix run examples/end_to_end.exs
#
# Both ends run with direct_ip: false, so IP transports are removed and the
# traffic has nowhere to go but the relay. Without that, two endpoints on one
# host connect over loopback and the relay is never exercised.

defmodule EndToEnd do
  alias IrohConsole.{Client, Server}
  alias IrohConsole.Auth.TOTP

  @relay_url System.get_env("IROH_RELAY_URL")
  @device IrohConsoleE2E.Device
  @timeout 60_000

  def run do
    IO.puts("relay: #{relay_name()}\n")

    secret = TOTP.generate_secret()
    network = network()

    device = start_device(network, secret)
    ticket = ticket_for(device)

    step("device online, ticket issued")

    {:ok, client} =
      Client.connect(
        target: ticket,
        network: network,
        direct_ip: false,
        owner: self(),
        # The operator's authenticator app, in one line.
        respond: fn _nonce -> {:ok, NimbleTOTP.verification_code(secret)} end
      )

    receive do
      {:iroh_console, :ready} -> step("TOTP accepted, shell attached")
      {:iroh_console, :closed, reason} -> fail("session refused: #{inspect(reason)}")
    after
      @timeout -> fail("no response from device")
    end

    banner = collect(1_500)

    if banner =~ "Interactive Elixir" do
      step("IEx banner received over the relay")
    else
      IO.puts("  note: no banner seen (got #{inspect(String.slice(banner, 0, 60))})")
    end

    :ok = Client.send_data(client, "1 + 1\n")
    output = collect(3_000)

    if output =~ "2" do
      step("evaluated `1 + 1` on the far end and got 2 back")
      IO.puts("\nPASS - console works end to end over #{relay_name()}")
    else
      fail("no result from the shell. Got: #{inspect(output)}")
    end

    Client.close(client)
  end

  defp network do
    case @relay_url do
      nil ->
        :n0

      url ->
        {:ok, relay} = IrohBeam.Relay.new(url)
        {:custom, [relay]}
    end
  end

  defp relay_name, do: @relay_url || "n0 default relays"

  defp start_device(network, secret) do
    {:ok, pid} =
      Server.start_link(
        name: @device,
        identity: {IrohConsole.Identity.Ephemeral, []},
        network: network,
        direct_ip: false,
        auth: {TOTP, secret: secret}
      )

    pid
  end

  defp ticket_for(_device) do
    :ok = IrohBeam.Endpoint.await_online(Server.endpoint(@device), @timeout)
    {:ok, ticket} = Server.ticket(@device)
    ticket
  end

  # The shell emits in bursts, so gather for a window rather than expecting a
  # single message.
  defp collect(window, acc \\ "") do
    receive do
      {:iroh_console, :data, data} -> collect(window, acc <> data)
      {:iroh_console, :closed, reason} -> fail("session ended early: #{inspect(reason)}")
    after
      window -> acc
    end
  end

  defp step(message), do: IO.puts("  [ok] #{message}")

  defp fail(message) do
    IO.puts("\nFAIL - #{message}")
    System.halt(1)
  end
end

EndToEnd.run()
