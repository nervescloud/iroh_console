defmodule IrohConsole.Auth.TOTP do
  @moduledoc """
  Time-based one-time passwords (RFC 6238), via `NimbleTOTP`.

  Chosen as the first adapter because it needs no infrastructure: a shared
  secret and an authenticator app, and the library is useful to anyone. The
  tradeoffs below are real, though, and worth reading before a fleet depends on
  it.

  ## Configuration

      auth: {IrohConsole.Auth.TOTP, secret_path: "/data/iroh_console/totp.secret"}

    * `:secret` — the raw secret, or
    * `:secret_base32` — base32 as shown by authenticator apps, or
    * `:secret_path` — a file containing base32
    * `:drift` — periods of clock skew tolerated either side. Default `1`.
    * `:period`, `:digits`, `:algorithm` — as `NimbleTOTP`, defaults 30/6/`:sha`

  ## The clock

  TOTP needs the device and the operator to agree on the time. Many Nerves
  targets have no battery-backed clock and depend on NTP after boot, and a
  console is most wanted when a device is unhealthy — which correlates with bad
  time. `:drift` widens the window; the default of `1` accepts the previous and
  next period, so roughly ±30s.

  A clock that is obviously unset is reported as its own failure rather than a
  wrong code, because "authentication failed" on a device whose clock is at 1970
  is a genuinely confusing thing to debug.

  ## What this protects, and what it does not

  The device must store a secret that verifies the code, so anyone who extracts
  firmware from one device can generate codes for it — and for every device
  sharing that secret. Use a per-device secret, and understand that TOTP raises
  the cost of using a stolen operator key rather than surviving a device being
  physically taken.

  For a fleet, a challenge/response adapter where the device holds only a public
  key avoids that entirely: nothing on the device helps an attacker, because the
  device verifies a signature rather than knowing a secret.

  ## Reuse

  RFC 6238 requires a code be accepted only once. The last accepted period is
  tracked in ETS, owned by a process this adapter contributes to
  `IrohConsole.Server`'s supervision tree, so a code cannot be replayed within
  its window.
  """

  @behaviour IrohConsole.Auth

  require Logger

  alias IrohConsole.Auth.TOTP.Replay

  @default_drift 1
  @default_period 30

  # Any device clock earlier than this has clearly never synchronised; TOTP
  # cannot work and the operator deserves to be told which problem they have.
  @implausible_before 1_704_067_200

  @impl true
  def child_spec(opts), do: Replay.child_spec(opts)

  @impl true
  def challenge(_context), do: {:ok, IrohConsole.Auth.nonce()}

  @impl true
  def verify(context, _challenge, response) do
    opts = Map.get(context, :opts, [])

    with {:ok, secret} <- secret(opts),
         :ok <- check_clock(),
         :ok <- check_replay_available() do
      code = response |> to_string() |> String.trim()

      case matching_time(secret, code, opts) do
        nil ->
          {:error, :invalid_code}

        matched_at ->
          Replay.record(key(secret), matched_at)
          :ok
      end
    end
  end

  @doc "Generates a secret suitable for `:secret`."
  @spec generate_secret() :: binary()
  def generate_secret, do: NimbleTOTP.secret()

  @doc """
  An `otpauth://` URI for enrolling an authenticator app.

      IrohConsole.Auth.TOTP.provisioning_uri(secret, "NervesCloud", "device-1234")
  """
  @spec provisioning_uri(binary(), String.t(), String.t()) :: String.t()
  def provisioning_uri(secret, issuer, account),
    do: NimbleTOTP.otpauth_uri("#{issuer}:#{account}", secret, issuer: issuer)

  ## Internals

  # Each candidate period is checked with :since, so a code already accepted in
  # that period is refused even though it is still within the drift window.
  defp matching_time(secret, code, opts) do
    now = System.os_time(:second)
    period = Keyword.get(opts, :period, @default_period)
    drift = Keyword.get(opts, :drift, @default_drift)
    since = Replay.last_used(key(secret))

    validate_opts =
      opts
      |> Keyword.take([:period, :digits, :algorithm])
      |> Keyword.put(:since, since)

    Enum.find_value(-drift..drift, fn step ->
      at = now + step * period

      if NimbleTOTP.valid?(secret, code, Keyword.put(validate_opts, :time, at)) do
        at
      end
    end)
  end

  defp check_clock do
    if System.os_time(:second) < @implausible_before do
      Logger.error(
        "iroh_console: device clock is unset, so time-based codes cannot be checked. " <>
          "Wait for NTP, or use an adapter that does not depend on the clock."
      )

      {:error, :clock_unset}
    else
      :ok
    end
  end

  defp check_replay_available do
    if Replay.available?() do
      :ok
    else
      # Accepting codes without reuse tracking would silently weaken the scheme,
      # so this refuses instead.
      Logger.error("iroh_console: TOTP replay tracker is not running; refusing to verify")
      {:error, :replay_tracker_unavailable}
    end
  end

  defp key(secret), do: :crypto.hash(:sha256, secret)

  defp secret(opts) do
    cond do
      secret = Keyword.get(opts, :secret) -> {:ok, secret}
      encoded = Keyword.get(opts, :secret_base32) -> decode_base32(encoded)
      path = Keyword.get(opts, :secret_path) -> read_secret(path)
      true -> {:error, :no_secret_configured}
    end
  end

  defp read_secret(path) do
    case File.read(path) do
      {:ok, contents} -> contents |> String.trim() |> decode_base32()
      {:error, reason} -> {:error, {:secret_unreadable, path, reason}}
    end
  end

  defp decode_base32(encoded) do
    case encoded |> String.upcase() |> Base.decode32(padding: false) do
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, :secret_not_base32}
    end
  end
end

defmodule IrohConsole.Auth.TOTP.Replay do
  @moduledoc """
  Remembers the last period accepted for each secret, so a code cannot be used
  twice — which RFC 6238 requires of a verifier.

  Started by `IrohConsole.Server` when `IrohConsole.Auth.TOTP` is configured.
  State is deliberately in-memory: forgetting on restart re-opens a window of at
  most one period, whereas persisting it would put a write on the auth path.
  """

  use GenServer

  @table __MODULE__

  @doc """
  Starts the tracker.

  `IrohConsole.Server` does this for you when the TOTP adapter is configured;
  it is exposed for tests and for hosts wiring the adapter up by hand.
  """
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "The last accepted time for `key`, or nil."
  def last_used(key) do
    case :ets.lookup(@table, key) do
      [{^key, time}] -> time
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Records `time` as the last period accepted for `key`."
  def record(key, time), do: :ets.insert(@table, {key, time})

  @doc """
  Whether the tracker is running.

  `IrohConsole.Auth.TOTP` refuses to verify when it is not: accepting codes
  without reuse tracking would silently drop an RFC 6238 requirement.
  """
  def available?, do: :ets.whereis(@table) != :undefined

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
