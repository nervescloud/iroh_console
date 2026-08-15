defmodule IrohConsole.Server do
  @moduledoc """
  Runs the device side: an iroh endpoint, an acceptor, and a session per peer.

  Add it to your supervision tree:

      {IrohConsole.Server,
       identity: {IrohConsole.Identity.File, []},
       network: {:custom, [relay]},
       peer_allowlist: ["<operator-endpoint-id>"],
       auth: MyApp.ConsoleAuth}

  ## Options

    * `:identity` — `{module, opts}` implementing `IrohConsole.Identity`.
      Defaults to `IrohConsole.Identity.File`.
    * `:network` — passed to `IrohBeam.Endpoint`: `:n0`, `{:custom, relays}`, …
    * `:peer_allowlist` — `:all`, or endpoint ids (strings are parsed) that may
      connect. See "Who gets in" below.
    * `:auth` — `IrohConsole.Auth` implementation deciding who may connect,
      as `module` or `{module, opts}`.
    * `:alpn` — defaults to `"iroh-console/1"`.
    * `:max_sessions` — concurrent sessions, authenticated or not. Defaults to 4.
    * `:allow_unauthenticated` — opt in to running with no `:auth` adapter and an
      open allowlist. Defaults to false.
    * `:direct_ip` — defaults to true. False removes IP transports, forcing all
      traffic through the relay.
    * `:idle_timeout` — inactivity before a session is dropped. Defaults to 30
      minutes.
    * `:handshake_timeout` — covers stream setup and authentication together.
      Defaults to 10 seconds.
    * `:tty_opts` — passed through to `ExTTY`, e.g. `[remsh: :node@host]`.
    * `:name` — base name, so several servers can coexist.

  ## Who gets in

  `IrohConsole.Auth` is the mechanism. A challenge/response adapter lets an
  operator prove they hold a credential, so devices never need to know
  individual operators in advance — which matters, because a per-device
  allowlist naming every operator means a config change and an endpoint restart
  every time staff change, across the whole fleet.

  `:peer_allowlist` is still available and is genuinely stronger where it fits:
  it is enforced inside `IrohBeam.Endpoint`, below this library, so a peer that
  is not on it never reaches any code here. Use it as a second layer for
  high-value devices, or where the set of operators really is fixed. It cannot
  be the general answer because it is fixed at endpoint start.

  Because the allowlist defaults to `:all`, an unset `:auth` would mean anyone
  who learns the device's address gets a root shell. That combination refuses to
  start. If you genuinely want it, say so with `allow_unauthenticated: true`.

  ## Resource limits

  With `:all`, unauthenticated peers reach the handshake, so each one costs a
  process and a stream until it authenticates or the deadline expires.
  `:max_sessions` caps how many can exist at once; combined with
  `:handshake_timeout` that bounds what an unauthenticated peer can consume.

  ## Failure to start

  A misconfiguration logs an error and returns `:ignore` rather than raising.
  On a field device a boot loop is far worse than a missing console, and the
  rest of the application should still come up.
  """

  use Supervisor

  require Logger

  @default_alpn "iroh-console/1"
  @default_max_sessions 4

  @doc """
  Starts the device side under your supervision tree.

  Options are documented on this module. Returns `:ignore` rather than raising
  on a misconfiguration, so a bad console cannot boot-loop a device.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  The name of the underlying `IrohBeam.Endpoint`.

  Derived from the server's name, so callers do not have to know the convention.
  """
  @spec endpoint(atom()) :: atom()
  def endpoint(name \\ __MODULE__), do: Module.concat(name, "Endpoint")

  @doc """
  This device's address, once the endpoint is online.

  Returns `{:error, :not_running}` rather than exiting when the console has not
  started, since the callers that ask — a status banner, a health check — are
  exactly the ones that may ask before it has.
  """
  @spec addr(atom()) :: {:ok, struct()} | {:error, term()}
  def addr(name \\ __MODULE__) do
    IrohBeam.Endpoint.addr(endpoint(name))
  catch
    :exit, _reason -> {:error, :not_running}
  end

  @doc """
  A ticket an operator can connect with.

  Print it at boot, or publish it to your control plane — with address lookup
  disabled there is no other way for a client to find this device.
  """
  @spec ticket(atom()) :: {:ok, struct()} | {:error, term()}
  def ticket(name \\ __MODULE__) do
    with {:ok, addr} <- addr(name), do: IrohBeam.EndpointTicket.new(addr)
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    with {:ok, identity} <- fetch_identity(opts),
         {:ok, allowlist} <- parse_allowlist(Keyword.get(opts, :peer_allowlist, :all)),
         :ok <- check_access(allowlist, opts) do
      endpoint = Module.concat(name, Endpoint)
      sessions = Module.concat(name, Sessions)

      auth = normalise_auth(Keyword.get(opts, :auth))

      # The auth adapter comes first: a session must never reach an adapter
      # whose state has not started yet.
      children =
        auth_child(auth) ++
          [
            {DynamicSupervisor,
             name: sessions,
             strategy: :one_for_one,
             max_children: Keyword.get(opts, :max_sessions, @default_max_sessions)},
            endpoint_spec(endpoint, identity, allowlist, opts),
            {IrohConsole.Acceptor,
             name: Module.concat(name, Acceptor),
             endpoint: endpoint,
             sessions: sessions,
             session_opts: session_opts(opts)}
          ]

      # The acceptor holds the endpoint's name, and a session's stream belongs to
      # the endpoint that produced it, so neither outlives an endpoint restart.
      Supervisor.init(children, strategy: :one_for_all)
    else
      {:error, reason} ->
        Logger.error("iroh_console: not starting: #{reason}")
        :ignore
    end
  end

  defp endpoint_spec(endpoint, identity, allowlist, opts) do
    endpoint_opts = [
      name: endpoint,
      identity: identity,
      alpns: [Keyword.get(opts, :alpn, @default_alpn)],
      network: Keyword.get(opts, :network, :n0),
      peer_allowlist: allowlist,
      direct_ip: Keyword.get(opts, :direct_ip, true)
    ]

    %{id: :endpoint, start: {IrohBeam.Endpoint, :start_link, [endpoint_opts]}}
  end

  defp session_opts(opts) do
    opts
    |> Keyword.take([:auth, :tty_opts, :handshake_timeout, :idle_timeout])
    |> Keyword.put(:auth, normalise_auth(Keyword.get(opts, :auth)))
  end

  defp normalise_auth(nil), do: {IrohConsole.Auth.None, []}
  defp normalise_auth({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalise_auth(module) when is_atom(module), do: {module, []}

  # A stateful adapter is supervised here rather than by the host application,
  # so it cannot be left unstarted while still configured — for a security
  # control there is no sensible way to degrade when its state is missing.
  defp auth_child({module, opts}) do
    if Code.ensure_loaded?(module) and function_exported?(module, :child_spec, 1) do
      [{module, opts}]
    else
      []
    end
  end

  # An open allowlist is fine — that is the point of challenge/response — but
  # only when something actually challenges. Together with no auth adapter it
  # means an unauthenticated root shell, which should never be reachable by
  # forgetting an option.
  defp check_access(:all, opts) do
    {auth, _auth_opts} = normalise_auth(Keyword.get(opts, :auth))

    cond do
      Keyword.get(opts, :allow_unauthenticated, false) ->
        Logger.warning(
          "iroh_console: running with no :auth adapter and an open allowlist — " <>
            "any peer that learns this device's address gets a shell"
        )

        :ok

      auth == IrohConsole.Auth.None ->
        {:error,
         "peer_allowlist is :all and no :auth adapter is configured, which would let any peer " <>
           "that learns this device's address open a root shell. Configure :auth, restrict " <>
           ":peer_allowlist, or pass allow_unauthenticated: true if that is really intended"}

      true ->
        :ok
    end
  end

  defp check_access(_allowlist, _opts), do: :ok

  defp fetch_identity(opts) do
    {module, identity_opts} =
      case Keyword.get(opts, :identity, {IrohConsole.Identity.File, []}) do
        {module, identity_opts} -> {module, identity_opts}
        module when is_atom(module) -> {module, []}
      end

    case module.fetch(identity_opts) do
      {:ok, identity} -> {:ok, identity}
      {:error, reason} -> {:error, "identity: #{reason}"}
    end
  end

  defp parse_allowlist(:all), do: {:ok, :all}

  defp parse_allowlist(ids) when is_list(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case parse_id(id) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_allowlist(other),
    do: {:error, "peer_allowlist must be :all or a list, got: #{inspect(other)}"}

  defp parse_id(id) when is_binary(id) do
    case IrohBeam.EndpointId.parse(id) do
      {:ok, endpoint_id} -> {:ok, endpoint_id}
      {:error, _error} -> {:error, "peer_allowlist contains an invalid endpoint id: #{id}"}
    end
  end

  defp parse_id(%IrohBeam.EndpointId{} = id), do: {:ok, id}

  defp parse_id(other),
    do: {:error, "peer_allowlist entries must be endpoint ids, got: #{inspect(other)}"}
end
