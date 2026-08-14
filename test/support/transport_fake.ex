defmodule IrohConsole.TransportFake do
  @moduledoc """
  A transport backed by a process, so session behaviour can be driven byte by
  byte without two endpoints and a relay.
  """

  @behaviour IrohConsole.Transport

  use GenServer

  # The behaviour names this callback send/2, colliding with Kernel.send/2.
  import Kernel, except: [send: 2]

  alias IrohConsole.Frame

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok)

  ## Driving the peer side

  @doc "Queues bytes for the session to read."
  def push(pid, data), do: GenServer.call(pid, {:push, {:ok, data}})

  @doc "Queues a frame for the session to read."
  def push_frame(pid, frame),
    do: push(pid, frame |> Frame.encode!() |> IO.iodata_to_binary())

  @doc "Signals the peer closed its send half."
  def push_eof(pid), do: GenServer.call(pid, {:push, :eof})

  @doc "Everything the session has written so far."
  def written(pid), do: GenServer.call(pid, :written)

  @doc "Everything the session has written, decoded."
  def frames(pid) do
    {:ok, frames, _rest} = pid |> written() |> Frame.decode_all()
    frames
  end

  def closed?(pid), do: GenServer.call(pid, :closed?)

  ## Transport callbacks

  # Tests hand a ready handle to both sides, so setting up is the identity.
  @impl IrohConsole.Transport
  def accept(pid, _timeout), do: {:ok, pid}

  @impl IrohConsole.Transport
  def open(pid, _timeout), do: {:ok, pid}

  @impl IrohConsole.Transport
  def send(pid, data), do: GenServer.call(pid, {:write, data})

  @impl IrohConsole.Transport
  def recv(pid, _max_bytes, timeout) do
    GenServer.call(pid, :recv, timeout)
  catch
    :exit, _reason -> {:error, :timeout}
  end

  @impl IrohConsole.Transport
  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _reason -> :ok
  end

  ## Server

  @impl GenServer
  def init(:ok), do: {:ok, %{queue: [], written: [], waiting: nil, closed: false}}

  @impl GenServer
  def handle_call({:push, item}, _from, %{waiting: nil} = state) do
    {:reply, :ok, %{state | queue: state.queue ++ [item]}}
  end

  def handle_call({:push, item}, _from, %{waiting: waiting} = state) do
    GenServer.reply(waiting, item)
    {:reply, :ok, %{state | waiting: nil}}
  end

  def handle_call(:recv, from, %{queue: []} = state) do
    {:noreply, %{state | waiting: from}}
  end

  def handle_call(:recv, _from, %{queue: [item | rest]} = state) do
    {:reply, item, %{state | queue: rest}}
  end

  def handle_call({:write, data}, _from, state) do
    {:reply, :ok, %{state | written: [data | state.written]}}
  end

  def handle_call(:written, _from, state) do
    {:reply, state.written |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  def handle_call(:closed?, _from, state), do: {:reply, state.closed, state}

  def handle_call(:close, _from, state), do: {:reply, :ok, %{state | closed: true}}
end
