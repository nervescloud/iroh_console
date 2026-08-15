defmodule IrohConsole.NervesHubLink do
  @moduledoc """
  Reports this device's iroh identity to NervesHub as an external identity.

  Implements NervesHubLink's `external_identity` extension provider contract, so
  the device's endpoint id and current ticket appear on its page in NervesHub
  without an operator having to get a console on it first.

      # config/target.exs
      config :nerves_hub_link,
        external_identity: [providers: [IrohConsole.NervesHubLink]]

  If the console runs under a name other than `IrohConsole.Server`:

      config :iroh_console, nerves_hub_link: [server: MyConsole]

  ## Choosing this or `IrohConsole.NervesHub`

  Both put the ticket on the device page, and you only want one of them.

  Prefer this module. The identity gets a first-class record on the device,
  with the endpoint id stored separately from the connection details, which is
  what lets NervesHub answer "which device holds this key?" later. It also
  reports once per connection rather than riding along with every health report.

  `IrohConsole.NervesHub` remains the option for a NervesHub that predates the
  external identity extension, since it needs nothing from the server beyond
  health metadata.

  ## What is reported

  The **endpoint id** is the identity: it is the key this device proves it
  holds, and it does not change. The **ticket** goes in the details, because it
  bundles that id together with the relay and direct addresses the device is
  currently reachable on — which do change. Only the ticket can be dialled.

  It is reported under the instance `"iroh_console"`. A device can run more than
  one iroh endpoint — this library's console, plus whatever the application
  itself uses iroh for — and each holds its own key. Naming the instance is what
  lets both be recorded as iroh without one overwriting the other. A provider for
  your own endpoint should pick its own name.

  Direct addresses are deliberately not reported as a separate field. They are
  already inside the ticket, they churn constantly, and repeating them would
  turn every reconnection into a change that NervesHub has to re-render.

  ## What this exposes

  A ticket says where a device is, not how to get in. Anyone reading it still
  has to satisfy the device's `IrohConsole.Auth` adapter. Publish it where you
  would publish an internal hostname, and keep an auth adapter configured.
  """

  alias IrohBeam.EndpointTicket

  @service "iroh"

  # Names which iroh endpoint on the device this is. A device can run more than
  # one — this library's console, plus whatever the application uses iroh for —
  # each with its own key. NervesHub keys the identity on this, so it has to stay
  # stable across reports.
  @instance "iroh_console"

  @typedoc """
  What NervesHubLink expects back from a provider.

  `:unavailable` means there is nothing to report right now and is logged
  quietly; `{:error, reason}` means something is actually wrong and is logged as
  a warning.
  """
  @type response() ::
          {:ok,
           %{
             service: String.t(),
             instance: String.t(),
             identifier: String.t(),
             details: map()
           }}
          | :unavailable
          | {:error, term()}

  @doc """
  This device's iroh identity, or why there isn't one yet.

  Returns `:unavailable` when the console is not running. That is the normal
  case on a unit where the console is not configured, and on any device during
  the window before it starts, so it must not be reported as an error — devices
  reconnect often, and a warning on each one would stop meaning anything.
  """
  @spec identity() :: response()
  def identity() do
    # One `addr/1` call, so the id and the ticket are the same snapshot. Asking
    # twice could pair an id with a ticket built moments later, after a relay
    # change.
    with {:ok, addr} <- IrohConsole.Server.addr(server()),
         {:ok, ticket} <- EndpointTicket.new(addr) do
      {:ok,
       %{
         service: @service,
         instance: @instance,
         identifier: to_string(addr.id),
         details: details(addr, ticket)
       }}
    else
      {:error, :not_running} -> :unavailable
      {:error, reason} -> {:error, reason}
    end
  end

  defp details(addr, ticket) do
    %{"ticket" => to_string(ticket), "relay_urls" => addr.relay_urls}
  end

  defp server() do
    :iroh_console
    |> Application.get_env(:nerves_hub_link, [])
    |> Keyword.get(:server, IrohConsole.Server)
  end
end
