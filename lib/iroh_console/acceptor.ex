defmodule IrohConsole.Acceptor do
  @moduledoc """
  Accepts console connections and hands each to its own session.

  Deliberately does almost nothing: it takes a connection and immediately starts
  a session under a `DynamicSupervisor`. Opening the stream and running the
  handshake happen inside that session, so a peer that connects and then stalls
  costs one idle process rather than blocking everyone behind it.
  """

  use GenServer

  require Logger

  @online_timeout :timer.seconds(30)
  @accept_timeout :timer.seconds(30)
  @error_backoff 250

  @doc """
  Starts the accept loop.

  Started by `IrohConsole.Server`, which supplies the endpoint name, the session
  supervisor and the options each session is given.
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      endpoint: Keyword.fetch!(opts, :endpoint),
      sessions: Keyword.fetch!(opts, :sessions),
      session_opts: Keyword.fetch!(opts, :session_opts)
    }

    {:ok, state, {:continue, :await_online}}
  end

  @impl true
  def handle_continue(:await_online, state) do
    case IrohBeam.Endpoint.await_online(state.endpoint, @online_timeout) do
      :ok ->
        log_ready(state)
        {:noreply, state, {:continue, :accept}}

      {:error, error} ->
        # Usually the relay being unreachable. Devices lose networking routinely,
        # so this retries rather than giving up and needing a restart.
        Logger.warning("iroh_console: endpoint not online yet: #{inspect(error)}")
        Process.sleep(@error_backoff)
        {:noreply, state, {:continue, :await_online}}
    end
  end

  def handle_continue(:accept, state) do
    case IrohBeam.Endpoint.accept(state.endpoint, timeout: @accept_timeout) do
      {:ok, connection} ->
        start_session(state, connection)
        {:noreply, state, {:continue, :accept}}

      # Nobody connected within the window. Entirely routine, and the field is
      # :category — IrohBeam.Error has no :reason, so matching on one silently
      # never fired and every idle window was logged as a failure.
      {:error, %{category: :timeout}} ->
        {:noreply, state, {:continue, :accept}}

      {:error, error} ->
        Logger.warning("iroh_console: accept failed: #{inspect(error)}")
        Process.sleep(@error_backoff)
        {:noreply, state, {:continue, :accept}}
    end
  end

  defp start_session(state, connection) do
    endpoint_id = IrohBeam.Connection.remote_id(connection)

    opts =
      state.session_opts
      |> Keyword.put(:connection, connection)
      |> Keyword.put(:endpoint_id, endpoint_id)

    case DynamicSupervisor.start_child(state.sessions, {IrohConsole.Session, opts}) do
      {:ok, _pid} ->
        Logger.info("iroh_console: session accepted from #{inspect(endpoint_id)}")

      {:error, reason} ->
        Logger.error("iroh_console: could not start session: #{inspect(reason)}")
    end
  end

  defp log_ready(state) do
    case IrohBeam.Endpoint.addr(state.endpoint) do
      {:ok, addr} ->
        Logger.info(
          "iroh_console: listening as #{inspect(addr.id)} via #{Enum.join(addr.relay_urls, ", ")}"
        )

      {:error, _error} ->
        Logger.info("iroh_console: listening")
    end
  end
end
