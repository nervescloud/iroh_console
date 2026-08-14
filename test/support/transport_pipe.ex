defmodule IrohConsole.TransportPipe do
  @moduledoc """
  Two handles wired back to back: what one side writes, the other reads.

  Lets `IrohConsole.Session` and `IrohConsole.Client` run against each other with
  no iroh, no relay and no terminal — so a disagreement between the two halves
  of the protocol fails a unit test rather than showing up as a hung shell.
  """

  @behaviour IrohConsole.Transport

  use GenServer

  import Kernel, except: [send: 2]

  @type handle :: {pid(), :a | :b}

  @spec start_link() :: {:ok, handle(), handle()}
  def start_link do
    {:ok, pid} = GenServer.start_link(__MODULE__, :ok)
    {:ok, {pid, :a}, {pid, :b}}
  end

  ## Transport callbacks

  @impl true
  def accept(handle, _timeout), do: {:ok, handle}

  @impl true
  def open(handle, _timeout), do: {:ok, handle}

  @impl true
  def send({pid, side}, data), do: GenServer.call(pid, {:write, side, data})

  @impl true
  def recv({pid, side}, _max_bytes, timeout) do
    GenServer.call(pid, {:recv, side}, timeout)
  catch
    :exit, _reason -> {:error, :timeout}
  end

  @impl true
  def close({pid, side}) do
    GenServer.call(pid, {:close, side})
  catch
    :exit, _reason -> :ok
  end

  ## Server

  @impl true
  def init(:ok), do: {:ok, %{a: empty(), b: empty()}}

  defp empty, do: %{queue: [], waiting: nil}

  defp other(:a), do: :b
  defp other(:b), do: :a

  @impl true
  def handle_call({:write, from, data}, _from, state) do
    {:reply, :ok, deliver(state, other(from), {:ok, data})}
  end

  def handle_call({:recv, side}, from, state) do
    case state[side] do
      %{queue: [item | rest]} = s ->
        {:reply, item, put_in(state[side], %{s | queue: rest})}

      %{queue: []} = s ->
        {:noreply, put_in(state[side], %{s | waiting: from})}
    end
  end

  # Closing one side is what the peer sees as end of stream.
  def handle_call({:close, side}, _from, state) do
    {:reply, :ok, deliver(state, other(side), :eof)}
  end

  defp deliver(state, side, item) do
    case state[side] do
      %{waiting: nil} = s ->
        put_in(state[side], %{s | queue: s.queue ++ [item]})

      %{waiting: waiting} = s ->
        GenServer.reply(waiting, item)
        put_in(state[side], %{s | waiting: nil})
    end
  end
end
