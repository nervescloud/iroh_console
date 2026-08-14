defmodule IrohConsole.Transport do
  @moduledoc """
  The byte pipe a session runs over.

  Exists as a behaviour for one reason: the session pump is the part most
  likely to harbour a subtle bug — partial frames, hostile input, teardown
  ordering — and testing it against a real iroh stream would mean standing up
  two endpoints and a relay for every assertion. A fake transport lets those
  cases be exercised directly.
  """

  @typedoc "Whatever the implementation needs to identify the pipe."
  @type handle :: term()

  @callback send(handle(), binary()) :: :ok | {:error, term()}
  @callback recv(handle(), max_bytes :: pos_integer(), timeout()) ::
              {:ok, binary()} | :eof | {:error, term()}
  @callback close(handle()) :: :ok

  @doc """
  Derives a handle from an accepted connection.

  Waiting for the peer to open its stream blocks, so it happens inside the
  session process rather than the acceptor — otherwise one peer that connects
  and then stalls would hold up every other pending connection.
  """
  @callback accept(connection :: term(), timeout()) :: {:ok, handle()} | {:error, term()}

  @doc "The dialling counterpart of `c:accept/2`."
  @callback open(connection :: term(), timeout()) :: {:ok, handle()} | {:error, term()}

  # A transport implements whichever side it plays.
  @optional_callbacks accept: 2, open: 2
end

defmodule IrohConsole.Transport.Iroh do
  @moduledoc """
  Carries a session over an `IrohBeam.Stream`.

  `IrohBeam.Stream.send/3` takes a binary rather than iodata, so frames are
  flattened here rather than at every call site.
  """

  @behaviour IrohConsole.Transport

  # The behaviour names this callback send/2, which collides with the
  # auto-imported Kernel.send/2.
  import Kernel, except: [send: 2]

  alias IrohBeam.{Connection, Stream}

  @impl true
  def accept(connection, timeout) do
    case Connection.accept_bi(connection, timeout: timeout) do
      {:ok, stream} -> {:ok, stream}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def open(connection, timeout) do
    case Connection.open_bi(connection, timeout: timeout) do
      {:ok, stream} -> {:ok, stream}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def send(stream, data) when is_binary(data) do
    case Stream.send(stream, data) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # IrohBeam.Stream.recv/3 requires a positive integer timeout and rejects
  # :infinity, so blocking reads are a long finite wait retried on timeout. The
  # behaviour keeps its :infinity semantics; only this adapter knows better.
  @long_wait :timer.minutes(5)

  @impl true
  def recv(stream, max_bytes, :infinity) do
    case Stream.recv(stream, max_bytes, timeout: @long_wait) do
      {:ok, data} -> {:ok, data}
      :eof -> :eof
      {:error, %{category: :timeout}} -> recv(stream, max_bytes, :infinity)
      {:error, error} -> {:error, error}
    end
  end

  def recv(stream, max_bytes, timeout) do
    case Stream.recv(stream, max_bytes, timeout: timeout) do
      {:ok, data} -> {:ok, data}
      :eof -> :eof
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def close(stream) do
    _ = Stream.abort(stream)
    :ok
  end
end
