defmodule IrohConsole.Client do
  @moduledoc """
  The dialling half of a console session.

  Deliberately knows nothing about terminals. It dials, answers the device's
  challenge, and then acts as a byte pipe, reporting to an owner process:

    * `{:iroh_console, :ready}` — authenticated, the shell is live
    * `{:iroh_console, :data, binary}` — output from the device
    * `{:iroh_console, :closed, reason}` — the session ended

  `IrohConsole.Client.Terminal` attaches a real tty to that. Keeping them apart
  means the protocol can be tested without a terminal, and the terminal handling
  stays small enough to read.

  ## Answering the challenge

  `:respond` receives the device's nonce and returns `{:ok, response}`. For TOTP
  that is a prompt for the current code; for a capability adapter it would be a
  signature over the nonce. Returning `{:error, reason}` abandons the session
  without sending anything.
  """

  use GenServer

  require Logger

  alias IrohConsole.Frame

  @recv_bytes 64 * 1024
  @default_connect_timeout :timer.seconds(30)
  @default_handshake_timeout :timer.seconds(60)

  defstruct [
    :transport,
    :handle,
    :connection,
    :owner,
    :respond,
    :handshake_timeout,
    :reader,
    buffer: <<>>
  ]

  @doc """
  Dials `target` and returns a connected client.

  `target` is anything `IrohBeam.Endpoint.connect/4` accepts — usually an
  `IrohBeam.EndpointTicket`. Starts an endpoint of its own, so the caller does
  not have to.

  ## Options

    * `:target` — required
    * `:network` — `:n0`, `{:custom, relays}`, … as `IrohBeam.Endpoint`
    * `:identity` — `{module, opts}` implementing `IrohConsole.Identity`.
      Defaults to `IrohConsole.Identity.Ephemeral`: an operator usually wants a
      throwaway key, unless the device pins an allowlist.
    * `:direct_ip` — defaults to true. False removes IP transports, so the
      connection must go via the relay.
    * `:alpn`, `:respond`, `:owner`, and the timeouts, as `start_link/1`
  """
  @spec connect(keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(opts) do
    target = Keyword.fetch!(opts, :target)
    alpn = Keyword.get(opts, :alpn, "iroh-console/1")

    identity_spec = Keyword.get(opts, :identity, {IrohConsole.Identity.Ephemeral, []})
    {identity_mod, identity_opts} = normalise(identity_spec)

    with {:ok, identity} <- identity_mod.fetch(identity_opts),
         {:ok, endpoint} <-
           IrohBeam.Endpoint.start_link(
             identity: identity,
             alpns: [alpn],
             network: Keyword.get(opts, :network, :n0),
             # direct_ip: false removes IP transports entirely, forcing traffic
             # through the relay. Useful for proving the relay path works.
             direct_ip: Keyword.get(opts, :direct_ip, true)
           ),
         :ok <- IrohBeam.Endpoint.await_online(endpoint, connect_timeout(opts)),
         {:ok, connection} <-
           IrohBeam.Endpoint.connect(endpoint, target, alpn, timeout: connect_timeout(opts)) do
      opts
      |> Keyword.put(:connection, connection)
      |> Keyword.put_new(:owner, self())
      |> start_link()
    end
  end

  @doc "Starts a client over an already-established connection."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Sends keystrokes to the device."
  @spec send_data(GenServer.server(), binary()) :: :ok | {:error, term()}
  def send_data(client, data) when is_binary(data),
    do: GenServer.call(client, {:frame, {:data, data}})

  @doc "Tells the device the terminal has been resized."
  @spec resize(GenServer.server(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, term()}
  def resize(client, width, height),
    do: GenServer.call(client, {:frame, {:resize, width, height}})

  @doc """
  Ends the session.

  The device sees the stream close and tears down its shell, so this is a clean
  disconnect rather than an abandoned session left to time out.
  """
  @spec close(GenServer.server()) :: :ok
  def close(client), do: GenServer.stop(client, :normal)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      transport: Keyword.get(opts, :transport, IrohConsole.Transport.Iroh),
      handle: Keyword.get(opts, :handle),
      connection: Keyword.get(opts, :connection),
      owner: Keyword.get(opts, :owner, self()),
      respond: Keyword.get(opts, :respond, &prompt_for_response/1),
      handshake_timeout: Keyword.get(opts, :handshake_timeout, @default_handshake_timeout)
    }

    {:ok, state, {:continue, :handshake}}
  end

  @impl true
  def handle_continue(:handshake, state) do
    deadline = System.monotonic_time(:millisecond) + state.handshake_timeout

    with {:ok, state} <- ensure_handle(state, deadline),
         :ok <- send_frame(state, {:hello, Frame.protocol_version()}),
         {:ok, state} <- authenticate(state, deadline) do
      {:ok, reader} = start_reader(state)
      notify(state, {:iroh_console, :ready})
      {:noreply, %{state | reader: reader}}
    else
      {:error, reason} ->
        notify(state, {:iroh_console, :closed, reason})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call({:frame, frame}, _from, state) do
    {:reply, send_frame(state, frame), state}
  end

  @impl true
  def handle_info({:frame, {:data, data}}, state) do
    notify(state, {:iroh_console, :data, data})
    {:noreply, state}
  end

  def handle_info({:frame, {:error_message, message}}, state) do
    notify(state, {:iroh_console, :closed, {:refused, message}})
    {:stop, :normal, state}
  end

  def handle_info({:frame, unexpected}, state) do
    Logger.warning("iroh_console: unexpected frame from device: #{inspect(unexpected)}")
    notify(state, {:iroh_console, :closed, :protocol_error})
    {:stop, :normal, state}
  end

  def handle_info({:transport, :eof}, state) do
    notify(state, {:iroh_console, :closed, :eof})
    {:stop, :normal, state}
  end

  def handle_info({:transport, {:error, reason}}, state) do
    notify(state, {:iroh_console, :closed, reason})
    {:stop, :normal, state}
  end

  def handle_info({:protocol_error, reason}, state) do
    notify(state, {:iroh_console, :closed, {:protocol_error, reason}})
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Same reasoning as the session: the reader is linked, so it must be
    # unlinked before being killed or its exit overrides ours.
    if state.reader do
      Process.unlink(state.reader)
      Process.exit(state.reader, :kill)
    end

    if state.handle, do: state.transport.close(state.handle)
    :ok
  end

  ## Handshake

  defp ensure_handle(%{handle: nil, connection: nil}, _deadline), do: {:error, :no_connection}

  defp ensure_handle(%{handle: nil, connection: connection} = state, deadline) do
    case state.transport.open(connection, remaining(deadline)) do
      {:ok, handle} -> {:ok, %{state | handle: handle}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_handle(state, _deadline), do: {:ok, state}

  defp authenticate(state, deadline) do
    case recv_frame(state, deadline) do
      {:ok, :ready, state} ->
        {:ok, state}

      {:ok, {:challenge, nonce}, state} ->
        with {:ok, response} <- state.respond.(nonce),
             :ok <- send_frame(state, {:response, response}) do
          await_ready(state, deadline)
        end

      {:ok, {:error_message, message}, _state} ->
        {:error, {:refused, message}}

      {:ok, frame, _state} ->
        {:error, {:unexpected_frame, frame}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_ready(state, deadline) do
    case recv_frame(state, deadline) do
      {:ok, :ready, state} -> {:ok, state}
      {:ok, {:error_message, message}, _state} -> {:error, {:refused, message}}
      {:ok, frame, _state} -> {:error, {:unexpected_frame, frame}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_frame(state, deadline) do
    case Frame.decode(state.buffer) do
      {:ok, frame, rest} ->
        {:ok, frame, %{state | buffer: rest}}

      {:error, reason} ->
        {:error, reason}

      :more ->
        if remaining(deadline) <= 0 do
          {:error, :handshake_timeout}
        else
          case state.transport.recv(state.handle, @recv_bytes, remaining(deadline)) do
            {:ok, data} -> recv_frame(%{state | buffer: state.buffer <> data}, deadline)
            :eof -> {:error, :closed}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  ## Plumbing

  defp start_reader(%{transport: transport, handle: handle, buffer: buffer}) do
    client = self()
    Task.start_link(fn -> reader_loop(transport, handle, client, buffer) end)
  end

  defp reader_loop(transport, handle, client, buffer) do
    case Frame.decode_all(buffer) do
      {:ok, frames, rest} ->
        Enum.each(frames, &send(client, {:frame, &1}))

        case transport.recv(handle, @recv_bytes, :infinity) do
          {:ok, data} -> reader_loop(transport, handle, client, rest <> data)
          :eof -> send(client, {:transport, :eof})
          {:error, reason} -> send(client, {:transport, {:error, reason}})
        end

      {:error, reason} ->
        send(client, {:protocol_error, reason})
    end
  end

  defp send_frame(state, frame) do
    state.transport.send(state.handle, frame |> Frame.encode!() |> IO.iodata_to_binary())
  end

  defp notify(state, message), do: send(state.owner, message)

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp connect_timeout(opts), do: Keyword.get(opts, :connect_timeout, @default_connect_timeout)

  defp normalise({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalise(module) when is_atom(module), do: {module, []}

  defp prompt_for_response(_nonce) do
    case IO.gets("code: ") do
      :eof -> {:error, :no_response}
      {:error, reason} -> {:error, reason}
      input -> {:ok, String.trim(input)}
    end
  end
end
