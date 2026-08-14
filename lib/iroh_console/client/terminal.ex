defmodule IrohConsole.Client.Terminal do
  @moduledoc """
  Attaches the local terminal to a connected `IrohConsole.Client`.

  ## Raw mode has to come from outside

  The BEAM cannot put its own terminal into raw mode. Port children are forked
  from `erl_child_setup`, which has no controlling terminal, so `stty ...
  </dev/tty` fails from inside the VM no matter which terminal launched it —
  `System.cmd("sh", ["-c", "tty"])` returns `not a tty` even from an interactive
  shell.

  The shell that *starts* the VM can do it, and the VM inherits the terminal on
  stdin. So use the wrapper, generating one into your project first:

      mix iroh_console.gen.script
      bin/iroh-console TICKET --relay https://relay.example.com

  which is just `stty raw -echo`, the mix task, and `stty` restored on exit.

  Without it the session still runs, but the terminal stays line-buffered: input
  reaches the device only when you press Enter, rather than as you type. Usable
  for a quick command, unpleasant for real work — so the session says so the
  first time it notices, rather than leaving you to wonder.

  Local echo is handled separately and does not need the wrapper: `attach/2` sets
  `echo: false` through `:io.setopts/2`, which is exposed as an io option even
  though canonical mode is not. Without it the device's echo and the terminal's
  own would both appear, showing everything typed twice.

  ## Detaching

  Keystrokes go to the device, Ctrl-C included, since that is how you interrupt
  something in IEx. Press `Ctrl-]` to detach (configurable with `:escape`).

  ## Resizing

  Erlang does not expose `SIGWINCH`, so the size is polled. It is read with
  `:io.columns/1` rather than by shelling out, which is cheap enough to do
  every second and works where `stty` cannot.
  """

  alias IrohConsole.Client

  @escape <<0x1D>>
  @poll_interval 1_000
  # Generous: with the bare mix task the operator is being prompted for a code
  # during this window.
  @ready_timeout :timer.minutes(2)

  @doc """
  Connects to `target` and attaches this terminal, returning when the session
  ends. Takes the same options as `IrohConsole.Client.connect/1`.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts) do
    with {:ok, client} <- Client.connect(Keyword.put(opts, :owner, self())) do
      attach(client, opts)
    end
  end

  @doc "Attaches this terminal to an already-connected client."
  @spec attach(pid(), keyword()) :: :ok | {:error, term()}
  def attach(client, opts \\ []) do
    if terminal?() do
      # echo: false is the one that matters, and it has to come from here rather
      # than from stty. Since OTP 26 the -noshell device is user_drv, which does
      # its own echo and sets its own termios — so anything the launching shell
      # configured is overridden by the time this runs.
      :io.setopts(:standard_io, binary: true, echo: false)
      hint()

      try do
        session(client, Keyword.get(opts, :escape, @escape))
      after
        # The device's shell may have left the cursor mid-line.
        IO.write("\r\n")
      end
    else
      {:error, :not_a_terminal}
    end
  end

  ## Session

  defp session(client, escape) do
    # Wait before touching the client at all. Client.connect/1 returns once
    # init/1 has run, but the handshake happens in handle_continue — so the
    # process is busy, and may be blocked prompting for a credential. Calling
    # into it here is a guaranteed timeout, not a race.
    with :ok <- await_ready() do
      attached(client, escape)
    end
  end

  defp await_ready do
    receive do
      {:iroh_console, :ready} -> :ok
      {:iroh_console, :closed, {:refused, message}} -> {:error, {:refused, message}}
      {:iroh_console, :closed, reason} -> {:error, reason}
    after
      @ready_timeout -> {:error, :handshake_timeout}
    end
  end

  defp attached(client, escape) do
    parent = self()
    size = report_size(client, nil)
    reader = spawn_link(fn -> stdin_loop(parent) end)
    {:ok, timer} = :timer.send_interval(@poll_interval, :poll_size)

    result = loop(client, escape, size, _cooked_warned? = false)

    :timer.cancel(timer)
    Process.unlink(reader)
    Process.exit(reader, :kill)
    result
  end

  defp loop(client, escape, size, warned?) do
    receive do
      {:iroh_console, :ready} ->
        loop(client, escape, size, warned?)

      {:iroh_console, :data, data} ->
        IO.binwrite(data)
        loop(client, escape, size, warned?)

      {:iroh_console, :closed, reason} ->
        closed(reason)

      {:stdin, :eof} ->
        :ok

      {:stdin, ^escape} ->
        :ok

      {:stdin, data} ->
        case Client.send_data(client, data) do
          :ok -> loop(client, escape, size, warn_if_cooked(data, warned?))
          {:error, reason} -> {:error, reason}
        end

      :poll_size ->
        loop(client, escape, report_size(client, size), warned?)
    end
  end

  # In raw mode Enter arrives as CR, because ICRNL is off. A bare LF means the
  # line discipline translated it, which means the terminal is still cooked —
  # so input only arrives on Enter and is echoed locally as well as by the
  # device, which looks like everything being typed twice.
  #
  # A pasted newline can trip this in raw mode too, hence advice rather than an
  # error, and only once per session.
  defp warn_if_cooked(_data, true), do: true

  defp warn_if_cooked(data, false) do
    if :binary.match(data, "\n") != :nomatch do
      IO.write(
        "\r\niroh_console: this terminal is line-buffered, so input only reaches " <>
          "the device on Enter.\r\nFor a raw-mode session run the wrapper — " <>
          "generate one with `mix iroh_console.gen.script`.\r\n"
      )

      true
    else
      false
    end
  end

  defp closed(:eof), do: :ok
  defp closed({:refused, message}), do: {:error, {:refused, message}}
  defp closed(reason), do: {:error, reason}

  # Only sent when it actually changes, so the poll is invisible to the device.
  defp report_size(client, previous) do
    case terminal_size() do
      ^previous ->
        previous

      nil ->
        previous

      {width, height} = size ->
        _ = Client.resize(client, width, height)
        size
    end
  end

  defp stdin_loop(parent) do
    case IO.binread(:stdio, 1) do
      :eof ->
        send(parent, {:stdin, :eof})

      {:error, _reason} ->
        send(parent, {:stdin, :eof})

      data ->
        send(parent, {:stdin, data})
        stdin_loop(parent)
    end
  end

  ## Terminal
  #
  # Everything here goes through :io rather than stty, because the BEAM's own
  # stdio is connected to the terminal while anything it spawns is not.

  defp terminal?, do: match?({:ok, _columns}, :io.columns(:standard_io))

  defp terminal_size do
    with {:ok, columns} <- :io.columns(:standard_io),
         {:ok, rows} <- :io.rows(:standard_io) do
      {columns, rows}
    else
      _ -> nil
    end
  end

  # Written directly rather than logged: Logger metadata is clutter on a
  # console, and a bare \n steps the cursor instead of returning it, so anything
  # printed from here has to end \r\n and stay to one line.
  defp hint, do: IO.write("iroh_console: Ctrl-] to detach.\r\n")

  @doc """
  Reports what the local io device says about itself.

  For working out why a session misbehaves: `terminal:` should be true, and
  `echo:` false once attached. If echo is true the device's output will appear
  twice, once from here and once from the far end.
  """
  @spec diagnose() :: keyword()
  def diagnose, do: :io.getopts(:standard_io)
end
