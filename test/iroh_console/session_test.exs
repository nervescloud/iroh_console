defmodule IrohConsole.SessionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias IrohConsole.{Frame, Session, TransportFake, TTYFake}

  @endpoint_id "peer-endpoint-id"

  defmodule SecretAuth do
    @moduledoc false
    @behaviour IrohConsole.Auth

    @secret "correct horse"

    def secret, do: @secret

    @impl true
    def challenge(_context), do: {:ok, "fixed-nonce-for-the-test"}

    @impl true
    def verify(_context, challenge, response) do
      if IrohConsole.Auth.secure_compare(response, :crypto.hash(:sha256, challenge <> @secret)) do
        :ok
      else
        {:error, :bad_response}
      end
    end
  end

  defmodule FailingAuth do
    @moduledoc false
    @behaviour IrohConsole.Auth

    @impl true
    def challenge(_context), do: {:error, :adapter_unavailable}

    @impl true
    def verify(_context, _challenge, _response), do: {:error, :never_called}
  end

  defp start_session(opts) do
    {:ok, transport} = TransportFake.start_link()

    session_opts =
      [
        handle: transport,
        endpoint_id: @endpoint_id,
        transport: TransportFake,
        tty_mod: TTYFake,
        tty_opts: [test_pid: self()]
      ] ++ opts

    {:ok, session} = Session.start_link(session_opts)
    # A real client opens the stream by writing, so the hello always arrives
    # before anything else.
    unless opts[:skip_hello],
      do: TransportFake.push_frame(transport, {:hello, Frame.protocol_version()})

    {transport, session}
  end

  defp correct_response(nonce), do: :crypto.hash(:sha256, nonce <> SecretAuth.secret())

  # capture_log/1 runs the function in this process and returns only the log, so
  # the transport is stashed in the process dictionary to get it back out.
  defp start_session_capturing(opts) do
    key = make_ref()

    log =
      capture_log(fn ->
        {transport, _session} = start_session(opts)
        Process.put(key, transport)
        Process.sleep(150)
      end)

    {Process.get(key), log}
  end

  describe "with the second factor waived" do
    setup do
      {transport, session} = start_session(auth: IrohConsole.Auth.None)
      assert_receive {:tty_started, tty}, 1_000
      %{transport: transport, session: session, tty: tty}
    end

    test "tells the peer it is ready before any shell output", %{transport: transport} do
      assert [:ready | _] = TransportFake.frames(transport)
    end

    test "forwards peer keystrokes to the shell", %{transport: transport} do
      TransportFake.push_frame(transport, {:data, "1+1\n"})
      assert_receive {:tty_input, "1+1\n"}, 1_000
    end

    test "forwards shell output to the peer", %{transport: transport, tty: tty} do
      TTYFake.emit(tty, "iex(1)> ")
      assert_eventually(fn -> {:data, "iex(1)> "} in TransportFake.frames(transport) end)
    end

    test "forwards a resize to the shell", %{transport: transport} do
      TransportFake.push_frame(transport, {:resize, 120, 40})
      assert_receive {:tty_resize, 120, 40}, 1_000
    end

    test "handles several frames arriving in one read", %{transport: transport} do
      batched =
        [{:data, "a"}, {:resize, 10, 20}, {:data, "b"}]
        |> Enum.map_join(&(&1 |> Frame.encode!() |> IO.iodata_to_binary()))

      TransportFake.push(transport, batched)

      assert_receive {:tty_input, "a"}, 1_000
      assert_receive {:tty_resize, 10, 20}, 1_000
      assert_receive {:tty_input, "b"}, 1_000
    end

    test "reassembles a frame split across reads", %{transport: transport} do
      full = {:data, "split me"} |> Frame.encode!() |> IO.iodata_to_binary()
      <<head::binary-size(4), tail::binary>> = full

      TransportFake.push(transport, head)
      refute_receive {:tty_input, _}, 100

      TransportFake.push(transport, tail)
      assert_receive {:tty_input, "split me"}, 1_000
    end

    test "chunks shell output larger than one frame", %{transport: transport, tty: tty} do
      big = :binary.copy("x", Frame.max_payload() + 100)
      TTYFake.emit(tty, big)

      assert_eventually(fn ->
        data = for {:data, d} <- TransportFake.frames(transport), do: d
        IO.iodata_to_binary(data) == big
      end)
    end

    test "stops when the peer closes", %{transport: transport, session: session} do
      Process.flag(:trap_exit, true)
      TransportFake.push_eof(transport)
      assert_receive {:EXIT, ^session, :normal}, 1_000
    end
  end

  describe "with a challenge/response adapter" do
    test "admits a peer that answers correctly" do
      {transport, _session} = start_session(auth: SecretAuth)

      assert_eventually(fn -> match?([{:challenge, _} | _], TransportFake.frames(transport)) end)
      [{:challenge, nonce} | _] = TransportFake.frames(transport)

      TransportFake.push_frame(transport, {:response, correct_response(nonce)})

      assert_receive {:tty_started, _tty}, 1_000
      assert :ready in TransportFake.frames(transport)
    end

    test "refuses a wrong answer without saying why" do
      Process.flag(:trap_exit, true)
      {transport, session} = start_session(auth: SecretAuth)

      assert_eventually(fn -> match?([{:challenge, _} | _], TransportFake.frames(transport)) end)

      log =
        capture_log(fn ->
          TransportFake.push_frame(transport, {:response, "wrong"})
          assert_receive {:EXIT, ^session, :normal}, 1_000
        end)

      refute_received {:tty_started, _}
      assert {:error_message, "authentication failed"} in TransportFake.frames(transport)
      refute :ready in TransportFake.frames(transport)

      # The real reason stays on the device.
      assert log =~ "bad_response"
    end

    test "refuses a peer that answers with the wrong frame type" do
      Process.flag(:trap_exit, true)
      {transport, session} = start_session(auth: SecretAuth)

      assert_eventually(fn -> match?([{:challenge, _} | _], TransportFake.frames(transport)) end)

      capture_log(fn ->
        TransportFake.push_frame(transport, {:data, "not a response"})
        assert_receive {:EXIT, ^session, :normal}, 1_000
      end)

      refute_received {:tty_started, _}
      assert {:error_message, "authentication failed"} in TransportFake.frames(transport)
    end

    test "gives up on a peer that never answers" do
      Process.flag(:trap_exit, true)
      {transport, session} = start_session(auth: SecretAuth, handshake_timeout: 150)

      capture_log(fn -> assert_receive {:EXIT, ^session, :normal}, 2_000 end)

      refute_received {:tty_started, _}
      assert {:error_message, "authentication failed"} in TransportFake.frames(transport)
    end

    test "does not start a shell when the adapter itself fails" do
      Process.flag(:trap_exit, true)

      # Started inside capture_log: this adapter fails during the handshake,
      # which runs immediately on start_link, so the log is emitted before a
      # capture opened afterwards would see it.
      {transport, log} = start_session_capturing(auth: FailingAuth)

      refute_received {:tty_started, _}
      assert {:error_message, "authentication failed"} in TransportFake.frames(transport)
      assert log =~ "adapter_unavailable"
      assert_receive {:EXIT, _pid, :normal}, 1_000
    end
  end

  describe "protocol version" do
    test "refuses a client speaking a version it does not know" do
      Process.flag(:trap_exit, true)
      {transport, session} = start_session(auth: IrohConsole.Auth.None, skip_hello: true)

      capture_log(fn ->
        TransportFake.push_frame(transport, {:hello, 99})
        assert_receive {:EXIT, ^session, :normal}, 1_000
      end)

      refute_received {:tty_started, _}

      # A version mismatch is not a credential problem, and saying "authentication
      # failed" would send an operator chasing the wrong thing.
      assert Enum.any?(TransportFake.frames(transport), fn
               {:error_message, message} -> message =~ "unsupported protocol version 99"
               _ -> false
             end)
    end

    test "refuses a client that says anything before hello" do
      Process.flag(:trap_exit, true)
      {transport, session} = start_session(auth: IrohConsole.Auth.None, skip_hello: true)

      capture_log(fn ->
        TransportFake.push_frame(transport, {:data, "straight to business"})
        assert_receive {:EXIT, ^session, :normal}, 1_000
      end)

      refute_received {:tty_started, _}
    end
  end

  describe "hostile input" do
    test "tears down on a malformed frame rather than resynchronising" do
      Process.flag(:trap_exit, true)
      {transport, session} = start_session(auth: IrohConsole.Auth.None)
      assert_receive {:tty_started, _tty}, 1_000

      capture_log(fn ->
        # Unknown tag: the stream position is no longer trustworthy.
        TransportFake.push(transport, <<0x7F, 0::32>>)
        assert_receive {:EXIT, ^session, :normal}, 1_000
      end)
    end

    test "tears down on an implausible frame length" do
      Process.flag(:trap_exit, true)
      {transport, session} = start_session(auth: IrohConsole.Auth.None)
      assert_receive {:tty_started, _tty}, 1_000

      capture_log(fn ->
        TransportFake.push(transport, <<0x01, 0xFFFFFFFF::32>>)
        assert_receive {:EXIT, ^session, :normal}, 1_000
      end)
    end

    test "rejects a frame the peer has no business sending mid-session" do
      Process.flag(:trap_exit, true)
      {transport, session} = start_session(auth: IrohConsole.Auth.None)
      assert_receive {:tty_started, _tty}, 1_000

      capture_log(fn ->
        TransportFake.push_frame(transport, {:challenge, "i am the server now"})
        assert_receive {:EXIT, ^session, :normal}, 1_000
      end)
    end
  end

  describe "idle timeout" do
    test "drops a session that goes quiet" do
      Process.flag(:trap_exit, true)
      {transport, session} = start_session(auth: IrohConsole.Auth.None, idle_timeout: 150)
      assert_receive {:tty_started, _tty}, 1_000

      assert_receive {:EXIT, ^session, :normal}, 2_000
      assert {:error_message, "idle timeout"} in TransportFake.frames(transport)
    end
  end

  describe "teardown" do
    test "closes the transport and kills the reader" do
      Process.flag(:trap_exit, true)
      {transport, session} = start_session(auth: IrohConsole.Auth.None)
      assert_receive {:tty_started, _tty}, 1_000

      GenServer.stop(session, :normal)

      assert_eventually(fn -> TransportFake.closed?(transport) end)
    end
  end

  defp assert_eventually(fun, remaining \\ 1_000) do
    cond do
      fun.() -> :ok
      remaining <= 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && assert_eventually(fun, remaining - 10)
    end
  end
end
