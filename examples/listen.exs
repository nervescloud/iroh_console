# Runs the device half of a console, then prints everything needed to connect
# to it from another terminal (or another machine).
#
#   mix iroh_console.gen.script          # bin/iroh-console is generated, not committed
#   mix compile                          # do this first, see the note below
#   mix run --no-halt examples/listen.exs
#
# Defaults are the lowest-friction thing that works: n0's relays, and no second
# factor. Both are fine for trying this out on your own machine and wrong for
# anything else — see the warning it prints.
#
# Environment:
#
#   IROH_RELAY_URL        use this relay instead of n0's
#   IROH_RELAY_TOKEN      token, if that relay requires one
#   IROH_CONSOLE_TOTP=1   require a TOTP code. Implied by IROH_CONSOLE_SECRET.
#   IROH_CONSOLE_SECRET   base32 TOTP secret. Generated and printed if unset.
#   IROH_CONSOLE_IDENTITY where to keep the iroh key. Defaults to a file in the
#                         system temp dir, so the ticket survives a restart.
#   IROH_CONSOLE_RELAY_ONLY=1
#                         drop IP transports, forcing traffic through the relay.
#                         Useful for proving the relay path; leave unset to let
#                         the two ends hole-punch as they normally would.
#
# Note on running both halves from this project: mix takes a build lock, so
# compile once up front or the connect task may sit waiting behind this one.

defmodule Listener do
  alias IrohConsole.Auth.TOTP
  alias IrohConsole.Server

  @relay_url System.get_env("IROH_RELAY_URL")
  @relay_token System.get_env("IROH_RELAY_TOKEN")
  @name IrohConsoleExample.Listener
  @timeout 60_000

  def run do
    secret = if totp?(), do: secret(), else: nil

    case Server.start_link(server_options(secret)) do
      {:ok, _pid} ->
        :ok

      :ignore ->
        IO.puts(:stderr, "listener refused to start; see the error above")
        System.halt(1)
    end

    :ok = IrohBeam.Endpoint.await_online(Server.endpoint(@name), @timeout)
    {:ok, ticket} = Server.ticket(@name)
    {:ok, addr} = Server.addr(@name)

    report(ticket, addr, secret)

    # Stay alive. Server.start_link/1 links the supervisor to this process, and
    # a supervisor shuts down when its parent exits — even normally. Without
    # this the script would print its details and the listener would quietly
    # disappear, while --no-halt kept the VM running and made it look healthy.
    Process.sleep(:infinity)
  end

  defp server_options(secret) do
    base = [
      name: @name,
      identity: {IrohConsole.Identity.File, path: identity_path()},
      network: network(),
      direct_ip: !relay_only?(),
      idle_timeout: :timer.minutes(60)
    ]

    # With no adapter the server refuses to start unless unauthenticated access
    # is chosen explicitly — forgetting :auth should never quietly open a shell.
    case secret do
      nil -> base ++ [allow_unauthenticated: true]
      secret -> base ++ [auth: {TOTP, secret: secret}]
    end
  end

  defp network do
    case @relay_url do
      nil ->
        :n0

      url ->
        {:ok, relay} = IrohBeam.Relay.new(url, relay_opts())
        {:custom, [relay]}
    end
  end

  defp report(ticket, addr, secret) do
    IO.puts("""

    #{String.duplicate("=", 72)}
    iroh_console listener ready

      endpoint  #{inspect(addr.id)}
      relay     #{@relay_url || "n0 default relays"}
      transport #{if relay_only?(), do: "relay only (IP transports removed)", else: "direct or relay"}
      identity  #{identity_path()}
    #{auth_section(secret)}
    Connect from another terminal, in the project root:

    #{connect_command(ticket)}

    Press Ctrl-] to detach. Use the wrapper rather than `mix iroh_console.connect`
    directly: it sets the terminal up first, which the BEAM cannot do for itself.
    #{String.duplicate("=", 72)}
    """)
  end

  defp auth_section(nil) do
    """

      auth      NONE — anyone holding this ticket gets a root shell here.
                Set IROH_CONSOLE_TOTP=1 to require a code.
    """
  end

  defp auth_section(secret) do
    """

      auth      TOTP

    Secret (base32), for an authenticator app:

      #{Base.encode32(secret, padding: false)}

      #{TOTP.provisioning_uri(secret, "IrohConsole", "example-listener")}

    Current code: #{NimbleTOTP.verification_code(secret)}  (rotates every 30s)
    """
  end

  # Built here rather than inline: heredoc indentation is stripped at compile
  # time from the literal parts only, so interpolated text keeps whatever
  # whitespace it carries and continuation lines have to be indented by hand.
  defp connect_command(ticket) do
    flags =
      [
        if(@relay_url, do: "--relay #{@relay_url}"),
        if(relay_only?(), do: "--relay-only")
      ]
      |> Enum.reject(&is_nil/1)

    command = Enum.join(["  bin/iroh-console #{ticket}" | flags], " \\\n    ")

    # The wrapper is generated rather than committed, so it may not be there.
    if File.exists?("bin/iroh-console") do
      command
    else
      "  mix iroh_console.gen.script\n\n" <> command
    end
  end

  defp totp? do
    System.get_env("IROH_CONSOLE_TOTP") in ["1", "true"] or
      System.get_env("IROH_CONSOLE_SECRET") != nil
  end

  # A file-backed identity keeps the endpoint id — and therefore the ticket —
  # stable across restarts, so a ticket copied once keeps working.
  defp identity_path do
    System.get_env("IROH_CONSOLE_IDENTITY") ||
      Path.join([System.tmp_dir!(), "iroh_console", "listener.identity"])
  end

  defp secret do
    case System.get_env("IROH_CONSOLE_SECRET") do
      nil ->
        TOTP.generate_secret()

      encoded ->
        case Base.decode32(String.upcase(encoded), padding: false) do
          {:ok, secret} ->
            secret

          :error ->
            IO.puts(:stderr, "IROH_CONSOLE_SECRET is not valid base32")
            System.halt(1)
        end
    end
  end

  defp relay_only?, do: System.get_env("IROH_CONSOLE_RELAY_ONLY") in ["1", "true"]

  defp relay_opts do
    case @relay_token do
      nil -> []
      token -> [token: token]
    end
  end
end

Listener.run()
