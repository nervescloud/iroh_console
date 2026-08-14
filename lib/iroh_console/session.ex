defmodule IrohConsole.Session do
  @moduledoc """
  One accepted console session: a shell on one side, a byte pipe on the other.

  ## Shape

  Reading from the transport blocks, while `ExTTY` delivers output as messages,
  so a single process cannot do both. After the handshake a linked reader
  process owns the read side and forwards decoded frames here; this process owns
  the shell and every write.

  The handshake itself runs synchronously, before the reader starts. Frames
  cannot interleave during it, and there is no window where a peer's data reaches
  the shell before it has been authenticated.

  ## The client speaks first

  A QUIC stream is not signalled to the far side until the opener writes, so the
  device cannot greet a client that is waiting to be greeted — both would block.
  The client therefore opens with `{:hello, version}`, which doubles as version
  negotiation: a mismatch is refused with a message saying so, rather than being
  reported as an authentication failure and sending someone to check credentials
  that were never the problem.

  ## Trust

  The peer's `EndpointId` is already proven by the iroh handshake, and whether
  it may connect at all is enforced by `IrohBeam.Endpoint`'s `:peer_allowlist`
  before a connection is ever accepted. What happens here is the optional second
  factor — see `IrohConsole.Auth`.

  Failures are reported to the peer as a bare "authentication failed" and logged
  locally with the real reason, so a caller cannot probe for which part it got
  wrong.
  """

  use GenServer, restart: :temporary

  require Logger

  alias IrohConsole.Frame

  @recv_bytes 64 * 1024
  @default_handshake_timeout :timer.seconds(10)
  @default_idle_timeout :timer.minutes(30)

  defstruct [
    :transport,
    :handle,
    :connection,
    :tty_mod,
    :tty,
    :tty_opts,
    :auth,
    :context,
    :handshake_timeout,
    :idle_timeout,
    :reader,
    buffer: <<>>
  ]

  @doc """
  Starts a session over an already-accepted connection.

  ## Options

    * `:connection` — an accepted connection; the session opens the stream
      itself, so a peer that stalls cannot block the acceptor
    * `:handle` — an already-open transport handle, instead of `:connection`
    * `:endpoint_id` — required, the peer's proven endpoint id
    * `:auth` — `module` or `{module, opts}` implementing `IrohConsole.Auth`
    * `:transport` — defaults to `IrohConsole.Transport.Iroh`
    * `:tty_mod` — defaults to `ExTTY`
    * `:tty_opts` — passed through to the shell, e.g. `[remsh: :node@host]`
    * `:handshake_timeout` — deadline for the whole auth exchange
    * `:idle_timeout` — inactivity before the session is dropped
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {auth, auth_opts} = normalise_auth(Keyword.get(opts, :auth, IrohConsole.Auth.None))

    state = %__MODULE__{
      transport: Keyword.get(opts, :transport, IrohConsole.Transport.Iroh),
      handle: Keyword.get(opts, :handle),
      connection: Keyword.get(opts, :connection),
      tty_mod: Keyword.get(opts, :tty_mod, ExTTY),
      tty_opts: Keyword.get(opts, :tty_opts, []),
      auth: auth,
      context: %{endpoint_id: Keyword.fetch!(opts, :endpoint_id), opts: auth_opts},
      handshake_timeout: Keyword.get(opts, :handshake_timeout, @default_handshake_timeout),
      idle_timeout: Keyword.get(opts, :idle_timeout, @default_idle_timeout)
    }

    {:ok, state, {:continue, :handshake}}
  end

  @impl true
  def handle_continue(:handshake, state) do
    deadline = System.monotonic_time(:millisecond) + state.handshake_timeout

    result =
      with {:ok, state} <- ensure_handle(state, deadline),
           {:ok, state} <- await_hello(state, deadline),
           do: authenticate(state, deadline)

    case result do
      {:ok, state} ->
        :ok = send_frame(state, :ready)
        {:ok, tty} = state.tty_mod.start_link([handler: self()] ++ state.tty_opts)
        {:ok, reader} = start_reader(state)
        {:noreply, %{state | tty: tty, reader: reader}, state.idle_timeout}

      {:error, reason} ->
        Logger.warning("iroh_console: refusing session: #{inspect(reason)}")
        _ = send_frame(state, {:error_message, refusal(reason)})
        state.transport.close(state.handle)
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:frame, {:data, data}}, state) do
    :ok = state.tty_mod.send_text(state.tty, data)
    {:noreply, state, state.idle_timeout}
  end

  def handle_info({:frame, {:resize, width, height}}, state) do
    :ok = state.tty_mod.window_change(state.tty, width, height)
    {:noreply, state, state.idle_timeout}
  end

  # Only the peer's input and resizes are meaningful once running. Anything
  # else means we disagree about the protocol, which is not recoverable.
  def handle_info({:frame, unexpected}, state) do
    Logger.warning("iroh_console: unexpected frame from peer: #{inspect(unexpected)}")
    {:stop, :normal, state}
  end

  def handle_info({:tty_data, data}, state) do
    case send_data(state, data) do
      :ok -> {:noreply, state, state.idle_timeout}
      {:error, reason} -> {:stop, {:shutdown, {:transport, reason}}, state}
    end
  end

  def handle_info({:transport, :eof}, state), do: {:stop, :normal, state}

  def handle_info({:transport, {:error, reason}}, state),
    do: {:stop, {:shutdown, {:transport, reason}}, state}

  def handle_info({:protocol_error, reason}, state) do
    Logger.warning("iroh_console: protocol error: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info(:timeout, state) do
    _ = send_frame(state, {:error_message, "idle timeout"})
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state, state.idle_timeout}

  @impl true
  def terminate(_reason, state) do
    # A :normal exit does not propagate over a link, so the reader would
    # otherwise survive this process, blocked on recv forever. Closing the
    # transport usually unblocks it, but that relies on the implementation
    # aborting reads; killing it is unconditional.
    # Both the reader and the shell are linked, and a :normal exit does not
    # propagate over a link — so neither dies with this process unless it is
    # stopped explicitly. Unlink before killing: while still linked, their exit
    # signal comes straight back, overriding this process's own exit reason and
    # aborting terminate/2 before the transport is closed.
    stop_linked(state.reader)
    stop_linked(state.tty)

    if state.handle, do: state.transport.close(state.handle)
    :ok
  end

  defp stop_linked(nil), do: :ok

  defp stop_linked(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    :ok
  end

  defp normalise_auth({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalise_auth(module) when is_atom(module), do: {module, []}

  ## Handshake

  # One deadline spans opening the stream and the auth exchange, so a peer
  # cannot get a fresh budget for each phase.
  defp ensure_handle(%{handle: nil, connection: nil}, _deadline),
    do: {:error, :no_connection}

  defp ensure_handle(%{handle: nil, connection: connection} = state, deadline) do
    case state.transport.accept(connection, remaining(deadline)) do
      {:ok, handle} -> {:ok, %{state | handle: handle}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_handle(state, _deadline), do: {:ok, state}

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # A version mismatch is not an authentication failure, and saying so saves
  # an operator debugging a credential that was never the problem.
  defp refusal({:unsupported_version, version}),
    do: "unsupported protocol version #{version}, this device speaks #{Frame.protocol_version()}"

  defp refusal(_reason), do: "authentication failed"

  defp await_hello(state, deadline) do
    version = Frame.protocol_version()

    case recv_frame(state, deadline) do
      {:ok, {:hello, ^version}, state} -> {:ok, state}
      {:ok, {:hello, other}, _state} -> {:error, {:unsupported_version, other}}
      {:ok, frame, _state} -> {:error, {:unexpected_frame, frame}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authenticate(state, deadline) do
    case state.auth.challenge(state.context) do
      :skip ->
        {:ok, state}

      {:ok, nonce} ->
        with :ok <- send_frame(state, {:challenge, nonce}),
             {:ok, {:response, proof}, state} <- recv_frame(state, deadline),
             :ok <- state.auth.verify(state.context, nonce, proof) do
          {:ok, state}
        else
          {:ok, frame, _state} -> {:error, {:unexpected_frame, frame}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Deadline rather than a per-read timeout: a peer that trickles one byte
  # under the limit forever would otherwise hold the handshake open indefinitely.
  defp recv_frame(state, deadline) do
    case Frame.decode(state.buffer) do
      {:ok, frame, rest} ->
        {:ok, frame, %{state | buffer: rest}}

      {:error, reason} ->
        {:error, reason}

      :more ->
        remaining = remaining(deadline)

        if remaining <= 0 do
          {:error, :handshake_timeout}
        else
          case state.transport.recv(state.handle, @recv_bytes, remaining) do
            {:ok, data} -> recv_frame(%{state | buffer: state.buffer <> data}, deadline)
            :eof -> {:error, :closed}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  ## Reader

  defp start_reader(%{transport: transport, handle: handle, buffer: buffer}) do
    session = self()
    Task.start_link(fn -> reader_loop(transport, handle, session, buffer) end)
  end

  defp reader_loop(transport, handle, session, buffer) do
    case Frame.decode_all(buffer) do
      {:ok, frames, rest} ->
        Enum.each(frames, &send(session, {:frame, &1}))

        case transport.recv(handle, @recv_bytes, :infinity) do
          {:ok, data} -> reader_loop(transport, handle, session, rest <> data)
          :eof -> send(session, {:transport, :eof})
          {:error, reason} -> send(session, {:transport, {:error, reason}})
        end

      {:error, reason} ->
        send(session, {:protocol_error, reason})
    end
  end

  ## Writes

  defp send_frame(state, frame) do
    state.transport.send(state.handle, frame |> Frame.encode!() |> IO.iodata_to_binary())
  end

  defp send_data(state, data) do
    data
    |> chunk(Frame.max_payload())
    |> Enum.reduce_while(:ok, fn piece, :ok ->
      case send_frame(state, {:data, piece}) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp chunk(data, size) when byte_size(data) <= size, do: [data]

  defp chunk(data, size) do
    <<piece::binary-size(^size), rest::binary>> = data
    [piece | chunk(rest, size)]
  end
end
