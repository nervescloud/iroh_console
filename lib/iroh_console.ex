defmodule IrohConsole do
  @moduledoc """
  A remote IEx console for Nerves devices, over a peer-to-peer iroh connection.

  A device behind NAT, on cellular, or on a network you do not control is dialled
  by its public key rather than its address. iroh handles hole punching, and
  falls back to a relay when no direct path can be established.

  ## The two halves

  `IrohConsole.Server` runs on the device. It holds an iroh endpoint, accepts
  connections, and gives each one an `IrohConsole.Session` — an `ExTTY` shell on
  one side, a byte pipe on the other.

  `IrohConsole.Client` dials from the operator's machine and reports what the
  device sends to an owner process. `IrohConsole.Client.Terminal` attaches a real
  terminal to that, and `mix iroh_console.connect` wraps the pair.

  Between them, `IrohConsole.Frame` defines the wire format: tagged,
  length-prefixed frames carrying terminal data, resizes, and the auth exchange.

  ## Getting in

  Two mechanisms, at different layers:

    * `:peer_allowlist` on the endpoint names which public keys may connect at
      all. Enforced inside `IrohBeam.Endpoint`, below this library, so nothing
      here can wave a peer through. It is fixed at startup, which makes it a poor
      fit for a fleet whose operators change.

    * `IrohConsole.Auth` is consulted per session, after iroh has proven the
      peer's identity. `IrohConsole.Auth.TOTP` ships as an adapter. This is the
      mechanism intended for general use.

  An open allowlist with no auth adapter is an unauthenticated root shell, so
  `IrohConsole.Server` refuses to start in that combination unless
  `allow_unauthenticated: true` says it was deliberate.

  ## What a session is

  Unrestricted control of the device, as root on most Nerves systems. There is no
  meaningful way to sandbox IEx — anything reachable from a prompt is reachable
  from this. Treat access to it as equivalent to physical access.

  See the [README](readme.html) for setup, configuration and the security model.
  """
end
