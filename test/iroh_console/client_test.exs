defmodule IrohConsole.ClientTest do
  use ExUnit.Case, async: true

  alias IrohConsole.{Client, Session, TransportFake, TransportPipe, TTYFake}

  defmodule SecretAuth do
    @moduledoc false
    @behaviour IrohConsole.Auth

    @impl true
    def challenge(_context), do: {:ok, "nonce-for-the-test"}

    @impl true
    def verify(_context, challenge, response) do
      if response == expected(challenge), do: :ok, else: {:error, :bad_response}
    end

    def expected(challenge), do: :crypto.hash(:sha256, challenge) |> Base.encode16()
  end

  describe "against a fake device" do
    setup do
      {:ok, transport} = TransportFake.start_link()
      %{transport: transport}
    end

    defp start_client(transport, opts \\ []) do
      Client.start_link([handle: transport, transport: TransportFake, owner: self()] ++ opts)
    end

    test "reports ready when the device waives the challenge", %{transport: transport} do
      {:ok, _client} = start_client(transport)
      TransportFake.push_frame(transport, :ready)
      assert_receive {:iroh_console, :ready}, 1_000
    end

    test "answers a challenge and then reports ready", %{transport: transport} do
      {:ok, _client} = start_client(transport, respond: fn nonce -> {:ok, "answer:" <> nonce} end)

      TransportFake.push_frame(transport, {:challenge, "abc"})
      TransportFake.push_frame(transport, :ready)

      assert_receive {:iroh_console, :ready}, 1_000
      frames = TransportFake.frames(transport)
      # The hello has to come first: a stream is invisible to the peer until
      # the opener writes.
      assert [{:hello, _} | _] = frames
      assert {:response, "answer:abc"} in frames
    end

    test "surfaces the device's refusal rather than a bare failure", %{transport: transport} do
      Process.flag(:trap_exit, true)
      {:ok, _client} = start_client(transport)

      TransportFake.push_frame(transport, {:error_message, "authentication failed"})

      assert_receive {:iroh_console, :closed, {:refused, "authentication failed"}}, 1_000
    end

    test "sends nothing when the responder declines", %{transport: transport} do
      Process.flag(:trap_exit, true)
      {:ok, _client} = start_client(transport, respond: fn _ -> {:error, :cancelled} end)

      TransportFake.push_frame(transport, {:challenge, "abc"})

      assert_receive {:iroh_console, :closed, :cancelled}, 1_000
      # A cancelled prompt must not leak a guess to the device.
      refute Enum.any?(TransportFake.frames(transport), &match?({:response, _}, &1))
    end

    test "gives up when the device never speaks", %{transport: transport} do
      Process.flag(:trap_exit, true)
      {:ok, _client} = start_client(transport, handshake_timeout: 150)
      assert_receive {:iroh_console, :closed, reason}, 2_000
      assert reason in [:handshake_timeout, :timeout]
    end

    test "is busy until ready, which is why callers must wait for it", %{transport: transport} do
      # No frames pushed, so the client stays inside its handshake.
      {:ok, client} = start_client(transport)

      # Exactly the deadlock that crashed the terminal: connect/1 returns once
      # init/1 has run, but the handshake happens in handle_continue — and it may
      # be blocked prompting for a credential. Anything that calls in before
      # :ready arrives will time out rather than race.
      assert catch_exit(GenServer.call(client, {:frame, {:resize, 80, 24}}, 200))

      # Once ready, the same call is served immediately.
      TransportFake.push_frame(transport, :ready)
      assert_receive {:iroh_console, :ready}, 1_000
      assert Client.resize(client, 80, 24) == :ok
    end

    test "reports the device hanging up", %{transport: transport} do
      Process.flag(:trap_exit, true)
      {:ok, _client} = start_client(transport)
      TransportFake.push_eof(transport)
      assert_receive {:iroh_console, :closed, :closed}, 1_000
    end
  end

  describe "the password adapter, through a real handshake" do
    setup do
      {:ok, device_side, operator_side} = TransportPipe.start_link()

      {:ok, _session} =
        Session.start_link(
          handle: device_side,
          transport: TransportPipe,
          endpoint_id: "operator",
          auth: {IrohConsole.Auth.Password, password: "correct horse battery staple"},
          tty_mod: TTYFake,
          tty_opts: [test_pid: self()]
        )

      %{side: operator_side}
    end

    test "the right password gets a shell", %{side: side} do
      {:ok, _client} =
        Client.start_link(
          handle: side,
          transport: TransportPipe,
          owner: self(),
          respond: fn _nonce -> {:ok, "correct horse battery staple"} end
        )

      assert_receive {:iroh_console, :ready}, 2_000
      assert_receive {:tty_started, _tty}, 2_000
    end

    test "the wrong password gets nothing, and no shell is started", %{side: side} do
      Process.flag(:trap_exit, true)

      {:ok, _client} =
        Client.start_link(
          handle: side,
          transport: TransportPipe,
          owner: self(),
          respond: fn _nonce -> {:ok, "hunter2"} end
        )

      assert_receive {:iroh_console, :closed, {:refused, "authentication failed"}}, 2_000
      refute_received {:tty_started, _}
    end
  end

  describe "client and session against each other" do
    setup do
      {:ok, device_side, operator_side} = TransportPipe.start_link()

      {:ok, _session} =
        Session.start_link(
          handle: device_side,
          transport: TransportPipe,
          endpoint_id: "operator",
          auth: SecretAuth,
          tty_mod: TTYFake,
          tty_opts: [test_pid: self()]
        )

      %{operator_side: operator_side}
    end

    defp start_operator(operator_side, respond) do
      Client.start_link(
        handle: operator_side,
        transport: TransportPipe,
        owner: self(),
        respond: respond
      )
    end

    test "completes the handshake both sides believe in", %{operator_side: side} do
      {:ok, _client} = start_operator(side, &{:ok, SecretAuth.expected(&1)})

      assert_receive {:iroh_console, :ready}, 2_000
      assert_receive {:tty_started, _tty}, 2_000
    end

    test "carries keystrokes to the shell", %{operator_side: side} do
      {:ok, client} = start_operator(side, &{:ok, SecretAuth.expected(&1)})
      assert_receive {:iroh_console, :ready}, 2_000

      :ok = Client.send_data(client, "1+1\n")
      assert_receive {:tty_input, "1+1\n"}, 2_000
    end

    test "carries shell output back to the operator", %{operator_side: side} do
      {:ok, _client} = start_operator(side, &{:ok, SecretAuth.expected(&1)})
      assert_receive {:iroh_console, :ready}, 2_000
      assert_receive {:tty_started, tty}, 2_000

      TTYFake.emit(tty, "iex(1)> ")
      assert_receive {:iroh_console, :data, "iex(1)> "}, 2_000
    end

    test "carries a resize", %{operator_side: side} do
      {:ok, client} = start_operator(side, &{:ok, SecretAuth.expected(&1)})
      assert_receive {:iroh_console, :ready}, 2_000

      :ok = Client.resize(client, 132, 43)
      assert_receive {:tty_resize, 132, 43}, 2_000
    end

    test "a wrong answer is refused, and the operator is told", %{operator_side: side} do
      Process.flag(:trap_exit, true)
      {:ok, _client} = start_operator(side, fn _nonce -> {:ok, "wrong"} end)

      assert_receive {:iroh_console, :closed, {:refused, "authentication failed"}}, 2_000
      # No shell is started for a peer that failed.
      refute_received {:tty_started, _}
    end

    test "closing the operator side ends the session", %{operator_side: side} do
      Process.flag(:trap_exit, true)
      {:ok, client} = start_operator(side, &{:ok, SecretAuth.expected(&1)})
      assert_receive {:iroh_console, :ready}, 2_000
      assert_receive {:tty_started, tty}, 2_000

      ref = Process.monitor(tty)
      Client.close(client)

      # The device tears down rather than leaving an orphaned shell.
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end
  end
end
