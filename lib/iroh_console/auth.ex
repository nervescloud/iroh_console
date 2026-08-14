defmodule IrohConsole.Auth do
  @moduledoc """
  Decides whether an incoming console session is allowed.

  ## What an adapter is deciding

  By the time one is consulted, iroh has completed its handshake, so the peer's
  `EndpointId` is proven — it holds the matching private key. What an adapter
  adds is evidence about the *human* driving that key: that they hold a
  credential, not merely a machine that once had access.

  This is the mechanism intended for general use. `IrohBeam.Endpoint`'s
  `:peer_allowlist` is stronger where it fits — it is enforced below this library
  and an unlisted peer never reaches any code here — but it is fixed when the
  endpoint starts, so naming every operator on every device means a config change
  and a restart across the fleet each time staff change. An adapter is consulted
  per session and can decide with whatever is current.

  The two compose: use both for high-value devices.

  ## Why challenge/response rather than a code

  A device console is most valuable when the device is unhealthy, and an
  unhealthy device often has bad time. Many Nerves targets have no
  battery-backed clock and depend on NTP after boot; `nerves_time` persists a
  last-known clock across reboots, but it drifts. A 30-second TOTP window is an
  awkward thing to depend on precisely when you need to get in.

  So the contract is challenge/response, which needs no clock:

    * a clock-free adapter can have the operator sign the nonce with a key,
      leaving only public keys on the device
    * a TOTP adapter is still perfectly implementable — ignore the nonce and
      verify the code in `c:verify/3`

  Both fit; only one of them forces a clock into the contract.

  ## Adapters

  `IrohConsole.Auth.None` performs no check at all. It is deliberately explicit
  rather than the default, and `IrohConsole.Server` refuses to start with it
  alongside an open allowlist unless `allow_unauthenticated: true` confirms the
  intent — a console session is unrestricted control of the device.
  """

  @typedoc "What is known about the peer before an adapter is consulted."
  @type context :: %{
          required(:endpoint_id) => term(),
          required(:opts) => keyword()
        }

  @doc """
  Issues a challenge for this peer.

  Return `:skip` to admit this peer without a challenge — it is sent `:ready`
  immediately and `c:verify/3` is never called.
  """
  @callback challenge(context()) :: {:ok, binary()} | :skip | {:error, term()}

  @doc """
  Checks the peer's response to `challenge`.

  Anything other than `:ok` refuses the session. Return a reason for the device
  log; it is not disclosed to the peer, which is told only that it failed.
  """
  @callback verify(context(), challenge :: binary(), response :: binary()) ::
              :ok | {:error, term()}

  @doc """
  Supervision for adapters that need state.

  Optional. `IrohConsole.Server` starts this under its own tree when the adapter
  exports it, so a stateful adapter cannot be half-configured — an adapter whose
  state is missing has no safe way to fail open.
  """
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec()

  @optional_callbacks child_spec: 1

  @doc "A nonce with 256 bits of entropy, for adapters that want the default."
  @spec nonce() :: binary()
  def nonce, do: :crypto.strong_rand_bytes(32)

  @doc """
  Compares two binaries in constant time.

  Adapters comparing a secret must use this rather than `==/2`, which returns
  early on the first differing byte and leaks the length of a correct prefix.
  """
  @spec secure_compare(binary(), binary()) :: boolean()
  def secure_compare(left, right) when is_binary(left) and is_binary(right) do
    # byte_size/1 is not secret, and unequal lengths are already distinguishable
    # by timing on the comparison itself, so short-circuiting here costs nothing.
    byte_size(left) == byte_size(right) and constant_time_equal?(left, right, 0)
  end

  defp constant_time_equal?(<<>>, <<>>, acc), do: acc == 0

  defp constant_time_equal?(<<l, left::binary>>, <<r, right::binary>>, acc) do
    import Bitwise
    constant_time_equal?(left, right, bor(acc, bxor(l, r)))
  end
end

defmodule IrohConsole.Auth.None do
  @moduledoc """
  Admits every peer that reaches it.

  Only the proven `EndpointId` gates the session, so this is reasonable when
  `:peer_allowlist` is restricted and tightly held. With an open allowlist it
  means anyone who learns the device's address gets a root shell, which is why
  it must be configured by name and confirmed with `allow_unauthenticated: true`.
  """

  @behaviour IrohConsole.Auth

  @impl true
  def challenge(_context), do: :skip

  @impl true
  def verify(_context, _challenge, _response), do: :ok
end
