defmodule IrohConsole.TTYFake do
  @moduledoc """
  Stands in for `ExTTY`, reporting everything it is asked to do to a test
  process and letting the test make the "shell" produce output on demand.
  """

  use GenServer

  # ExTTY's surface, as used by IrohConsole.Session
  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{
      handler: Keyword.fetch!(opts, :handler),
      test_pid: Keyword.fetch!(opts, :test_pid)
    })
  end

  def send_text(pid, text), do: GenServer.call(pid, {:send_text, text})
  def window_change(pid, width, height), do: GenServer.call(pid, {:window_change, width, height})

  @doc "Makes the shell emit output, as ExTTY would."
  def emit(pid, data), do: GenServer.call(pid, {:emit, data})

  @impl true
  def init(state) do
    send(state.test_pid, {:tty_started, self()})
    {:ok, state}
  end

  @impl true
  def handle_call({:send_text, text}, _from, state) do
    send(state.test_pid, {:tty_input, text})
    {:reply, :ok, state}
  end

  def handle_call({:window_change, width, height}, _from, state) do
    send(state.test_pid, {:tty_resize, width, height})
    {:reply, :ok, state}
  end

  def handle_call({:emit, data}, _from, state) do
    send(state.handler, {:tty_data, data})
    {:reply, :ok, state}
  end
end
