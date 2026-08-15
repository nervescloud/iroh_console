defmodule IrohConsole.NervesHub do
  @moduledoc """
  Publishes this device's connection details through NervesHubLink's health
  metadata, so they are visible on the device's page in NervesHub.

      # config/target.exs
      config :nerves_hub_link,
        health: [
          metadata: %{
            "iroh_ticket" => {IrohConsole.NervesHub, :ticket, []},
            "iroh_endpoint_id" => {IrohConsole.NervesHub, :endpoint_id, []}
          }
        ]

  ## Why this is worth doing

  With address lookup disabled there is no ambient way to find a device — an
  operator needs its ticket, and the ticket only exists on the device. That
  normally means getting a console on it once, by serial or SSH, to read the
  ticket out.

  If NervesHub can already reach the device, this removes that step: the ticket
  arrives with every health report and is there on the device page when you need
  it. It also keeps working when the device's addresses change, because each
  report carries the current value rather than one captured at provisioning.

  ## The contract

  NervesHubLink resolves each metadata value at report time, accepting either a
  literal or an `{module, function, args}` tuple, and the health report requires
  string values. Both functions here return a plain string for that reason, with
  `"not running"` or `"offline"` in place of an error — the same wording as
  `IrohConsole.MOTD`.

  ## What it does not expose

  A ticket says where a device is, not how to get in. Anyone reading it still
  has to satisfy the device's `IrohConsole.Auth` adapter. It is closer to a
  hostname than to a credential — but it is also a standing invitation to try,
  so publish it only where you would publish an internal hostname, and keep an
  auth adapter configured.
  """

  @doc """
  This device's ticket, as a string.

  Pass `server: MyConsole` in the MFA's args if the console runs under a name
  other than `IrohConsole.Server`:

      {IrohConsole.NervesHub, :ticket, [[server: MyConsole]]}
  """
  @spec ticket(keyword()) :: String.t()
  def ticket(opts \\ []) do
    opts |> server() |> IrohConsole.Server.ticket() |> stringify()
  end

  @doc """
  This device's endpoint id, as a string.

  The value `:peer_allowlist` takes. Not connectable on its own — see
  `IrohConsole.MOTD` for why an id and a ticket are not interchangeable.
  """
  @spec endpoint_id(keyword()) :: String.t()
  def endpoint_id(opts \\ []) do
    case opts |> server() |> IrohConsole.Server.addr() do
      {:ok, addr} -> to_string(addr.id)
      error -> stringify(error)
    end
  end

  defp server(opts), do: Keyword.get(opts, :server, IrohConsole.Server)

  defp stringify({:ok, value}), do: to_string(value)
  defp stringify({:error, :not_running}), do: "not running"
  defp stringify({:error, _reason}), do: "offline"
end
