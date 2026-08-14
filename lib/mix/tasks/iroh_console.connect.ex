defmodule Mix.Tasks.IrohConsole.Connect do
  @shortdoc "Opens a remote IEx console on a device over iroh"

  @moduledoc """
  Connects to a device running `IrohConsole.Server` and attaches your terminal.

      mix iroh_console.gen.script      # once, to create the wrapper
      bin/iroh-console TICKET          # preferred: raw mode

      mix iroh_console.connect TICKET  # works, but line-buffered

  `TICKET` is an endpoint ticket printed by the device, or produced from its
  `IrohBeam.EndpointAddr`.

  ## Options

    * `--relay URL` — a custom relay. Repeatable. Without this, n0's relays are
      used, which will not reach a device configured against your own.
    * `--relay-token TOKEN` — token for a relay that requires one
    * `--code CODE` — the credential, if you would rather not be prompted: a
      TOTP code or a password, depending on the device's adapter.
      `--password` is an alias. Note either is visible in your shell history;
      `IROH_CONSOLE_CODE` is read too and does not have that problem.
    * `--alpn ALPN` — defaults to `iroh-console/1`
    * `--timeout MS` — connect timeout, defaults to 30000
    * `--relay-only` — drop IP transports, so traffic must go via the relay.
      Useful when a direct path is being attempted and failing.
    * `--identity-path PATH` — keep this client's key in a file, so its endpoint
      id is stable. Required if the device pins a `:peer_allowlist`; without it
      a throwaway key is generated per connection and the id changes each time.

  ## Detaching

  Press `Ctrl-]`. Everything else, Ctrl-C included, goes to the device.

  ## Raw mode

  `mix` runs the BEAM with `-noshell`, so Erlang's line editor is out of the way.
  But the BEAM still cannot put the terminal into raw mode itself — anything it
  spawns is forked without a controlling terminal — so run it through the
  wrapper, which sets raw mode in the shell first and restores it afterwards.
  `mix iroh_console.gen.script` writes one into your project. Without it the
  session works but stays line-buffered.
  """

  use Mix.Task

  alias IrohConsole.Client.Terminal

  @requirements ["app.config"]

  @switches [
    relay: :keep,
    relay_token: :string,
    code: :string,
    password: :string,
    alpn: :string,
    timeout: :integer,
    identity_path: :string,
    relay_only: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    ticket =
      case args do
        [ticket] -> ticket
        [] -> Mix.raise("expected a ticket: mix iroh_console.connect TICKET")
        _ -> Mix.raise("expected exactly one ticket")
      end

    {:ok, _apps} = Application.ensure_all_started(:iroh_console)

    with {:ok, parsed} <- parse_ticket(ticket),
         {:ok, network} <- build_network(opts) do
      connect(parsed, network, opts)
    else
      {:error, reason} -> Mix.raise(describe(reason))
    end
  end

  defp connect(ticket, network, opts) do
    result =
      Terminal.run(
        target: ticket,
        network: network,
        alpn: Keyword.get(opts, :alpn, "iroh-console/1"),
        connect_timeout: Keyword.get(opts, :timeout, 30_000),
        direct_ip: not Keyword.get(opts, :relay_only, false),
        identity: identity(opts),
        respond: responder(opts)
      )

    case result do
      :ok ->
        Mix.shell().info("session ended")

      {:error, reason} ->
        Mix.raise(describe(reason))
    end
  end

  # A code passed on the command line skips the prompt; otherwise ask once the
  # connection is up, so the code is entered as late as possible and is less
  # likely to expire mid-handshake.
  defp responder(opts) do
    case code(opts) do
      nil ->
        fn _nonce ->
          case Mix.shell().prompt("code or password:") do
            nil -> {:error, :no_response}
            input -> {:ok, String.trim(input)}
          end
        end

      code ->
        fn _nonce -> {:ok, code} end
    end
  end

  # An operator usually wants a throwaway key; a stable one is only needed when
  # the device pins an allowlist, so it is opt-in rather than the default.
  defp identity(opts) do
    case Keyword.get(opts, :identity_path) do
      nil -> {IrohConsole.Identity.Ephemeral, []}
      path -> {IrohConsole.Identity.File, path: path}
    end
  end

  # An empty environment variable means "not supplied" — bin/iroh-console only
  # exports it when something was typed, but treating "" as an answer would send
  # a blank code and burn a failed attempt.
  defp code(opts) do
    case Keyword.get(opts, :code) || Keyword.get(opts, :password) ||
           System.get_env("IROH_CONSOLE_CODE") do
      nil -> nil
      "" -> nil
      code -> String.trim(code)
    end
  end

  @doc false
  def build_network(opts) do
    token = Keyword.get(opts, :relay_token)

    case Keyword.get_values(opts, :relay) do
      [] ->
        {:ok, :n0}

      urls ->
        urls
        |> Enum.reduce_while({:ok, []}, fn url, {:ok, acc} ->
          case IrohBeam.Relay.new(url, relay_opts(token)) do
            {:ok, relay} -> {:cont, {:ok, [relay | acc]}}
            {:error, error} -> {:halt, {:error, {:bad_relay, url, error}}}
          end
        end)
        |> case do
          {:ok, relays} -> {:ok, {:custom, Enum.reverse(relays)}}
          error -> error
        end
    end
  end

  defp relay_opts(nil), do: []
  defp relay_opts(token), do: [token: token]

  defp parse_ticket(text) do
    case IrohBeam.EndpointTicket.parse(text) do
      {:ok, ticket} -> {:ok, ticket}
      {:error, _error} -> {:error, {:bad_ticket, text}}
    end
  end

  @doc false
  def describe({:bad_ticket, _text}),
    do: "that does not look like an endpoint ticket"

  def describe({:bad_relay, url, _error}), do: "invalid relay URL: #{url}"

  def describe({:refused, message}),
    do: "the device refused the session: #{message}"

  def describe(:not_a_terminal),
    do: "no controlling terminal — run this from an interactive shell"

  def describe(:handshake_timeout), do: "the device did not complete the handshake in time"
  def describe(:timeout), do: "timed out"
  def describe(:eof), do: "the device closed the session"
  def describe(reason), do: "could not connect: #{inspect(reason)}"
end
