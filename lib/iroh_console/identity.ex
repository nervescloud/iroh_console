defmodule IrohConsole.Identity do
  @moduledoc """
  Where the device's iroh secret key comes from.

  The key is the device's name: its public half is the `EndpointId` that appears
  in an operator's allowlist and in any records your control plane holds. That
  makes persistence a correctness requirement, not a convenience — an identity
  that changes on reboot silently invalidates every allowlist entry naming it.

  Implementations return whatever `IrohBeam.Endpoint` accepts for `:identity`:
  `{:file, path}`, an `IrohBeam.SecretKey`, or `:ephemeral`.
  """

  @type identity :: :ephemeral | {:file, Path.t()} | struct()

  @callback fetch(opts :: keyword()) :: {:ok, identity()} | {:error, term()}
end

defmodule IrohConsole.Identity.File do
  @moduledoc """
  Keeps the identity in a file, created on first use.

  On Nerves the default lives under `/data`, the application data partition,
  because that survives a firmware update — the root filesystem is read-only and
  is replaced wholesale on upgrade, so a key written there would be lost exactly
  when a fleet was updated. A factory reset still clears it.

  Off-device there is no `/data`, and rather than invent a path this refuses to
  start and asks for `:path`. Falling back to a temporary directory would look
  like it worked while quietly issuing a new identity on every boot.

  Note the private key is stored unencrypted, as iroh needs it at startup with
  no operator present. NervesKey cannot hold it — that is an ATECC608 part doing
  ECDSA P-256 for TLS client certificates, while iroh identities are ed25519 —
  so the security of this file is the security of the data partition.
  """

  @behaviour IrohConsole.Identity

  @data_dir "/data"
  @default_subpath "iroh_console/identity"

  @impl true
  def fetch(opts \\ []) do
    case Keyword.get(opts, :path) || default_path() do
      nil ->
        {:error,
         "no identity path: #{@data_dir} does not exist, so this is probably not a Nerves " <>
           "device. Configure an explicit path, e.g. identity: {IrohConsole.Identity.File, " <>
           "path: \"priv/iroh_console.identity\"}"}

      path ->
        with :ok <- ensure_parent(path), do: {:ok, {:file, path}}
    end
  end

  @doc "The default path, or `nil` when there is no data partition to put it in."
  @spec default_path() :: Path.t() | nil
  def default_path do
    if File.dir?(@data_dir), do: Path.join(@data_dir, @default_subpath)
  end

  defp ensure_parent(path) do
    dir = Path.dirname(path)
    pre_existing? = File.dir?(dir)

    with :ok <- File.mkdir_p(dir),
         :ok <- restrict(dir, pre_existing?) do
      :ok
    else
      {:error, reason} -> {:error, "cannot prepare #{dir}: #{:file.format_error(reason)}"}
    end
  end

  # Owner-only, because the key is unencrypted and directory permissions are the
  # only thing standing between it and any other user on the device.
  #
  # Only for a directory we created, though. Pointing :path at a file directly
  # inside somewhere shared — /tmp, or /data itself — would otherwise mean
  # chmodding a directory we do not own, which fails outright on a temp dir and
  # would be an unpleasant surprise on a mount point if it succeeded.
  defp restrict(_dir, true = _pre_existing), do: :ok
  defp restrict(dir, false = _pre_existing), do: File.chmod(dir, 0o700)
end

defmodule IrohConsole.Identity.Ephemeral do
  @moduledoc """
  A fresh identity on every start.

  For tests and host-side clients, where a stable name is not wanted. Never for
  a device: the `EndpointId` changes on every boot, so no allowlist can name it.
  """

  @behaviour IrohConsole.Identity

  @impl true
  def fetch(_opts), do: {:ok, :ephemeral}
end
