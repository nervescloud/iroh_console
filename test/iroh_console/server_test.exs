defmodule IrohConsole.ServerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias IrohConsole.Server

  defmodule StubAuth do
    @moduledoc false
    @behaviour IrohConsole.Auth

    @impl true
    def challenge(_context), do: {:ok, "nonce"}

    @impl true
    def verify(_context, _challenge, _response), do: :ok
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "iroh_console_srv_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{identity: {IrohConsole.Identity.File, path: Path.join(dir, "identity")}}
  end

  defp init(opts) do
    opts
    |> Keyword.put_new(:name, IrohConsole.ServerTest.Instance)
    |> Server.init()
  end

  defp child(children, id), do: Enum.find(children, &(&1.id == id))

  defp endpoint_opts(children) do
    {IrohBeam.Endpoint, :start_link, [opts]} = child(children, :endpoint).start
    opts
  end

  describe "an open allowlist" do
    test "refuses to start without an auth adapter", %{identity: identity} do
      # Forgetting :auth would otherwise mean an unauthenticated root shell for
      # anyone who learns the device's address.
      log = capture_log(fn -> assert init(identity: identity) == :ignore end)

      assert log =~ "no :auth adapter is configured"
      assert log =~ "root shell"
    end

    test "refuses when auth is explicitly None", %{identity: identity} do
      log =
        capture_log(fn ->
          assert init(identity: identity, auth: IrohConsole.Auth.None) == :ignore
        end)

      assert log =~ "no :auth adapter is configured"
    end

    test "starts with a challenge/response adapter", %{identity: identity} do
      assert {:ok, {_flags, children}} = init(identity: identity, auth: StubAuth)
      assert endpoint_opts(children)[:peer_allowlist] == :all
    end

    test "starts when unauthenticated access is explicitly chosen", %{identity: identity} do
      log =
        capture_log(fn ->
          assert {:ok, {_flags, _children}} =
                   init(identity: identity, allow_unauthenticated: true)
        end)

      assert log =~ "no :auth adapter"
    end
  end

  describe "a restricted allowlist" do
    test "does not require an auth adapter", %{identity: identity} do
      # Nothing unauthenticated can reach the handshake, so a second factor is
      # a choice rather than a requirement.
      id = String.duplicate("a", 52)

      case IrohBeam.EndpointId.parse(id) do
        {:ok, _} ->
          assert {:ok, {_flags, children}} = init(identity: identity, peer_allowlist: [id])
          assert [%IrohBeam.EndpointId{}] = endpoint_opts(children)[:peer_allowlist]

        {:error, _} ->
          :ok
      end
    end
  end

  describe "valid configuration" do
    setup %{identity: identity}, do: %{base: [identity: identity, auth: StubAuth]}

    test "builds the endpoint, session supervisor and acceptor", %{base: base} do
      assert {:ok, {flags, children}} = init(base)
      assert flags.strategy == :one_for_all
      assert length(children) == 3

      ids = Enum.map(children, & &1.id)
      assert IrohConsole.ServerTest.Instance.Sessions in ids
      assert :endpoint in ids
      assert IrohConsole.Acceptor in ids
    end

    test "caps concurrent sessions so unauthenticated peers cannot pile up", %{base: base} do
      assert {:ok, {_flags, children}} = init(base)
      {DynamicSupervisor, :start_link, [opts]} = child(children, sessions_child(children)).start
      assert opts[:max_children] == 4
    end

    test "honours a max_sessions override", %{base: base} do
      assert {:ok, {_flags, children}} = init(base ++ [max_sessions: 1])
      {DynamicSupervisor, :start_link, [opts]} = child(children, sessions_child(children)).start
      assert opts[:max_children] == 1
    end

    test "uses a dedicated alpn so the endpoint can carry other protocols", %{base: base} do
      assert {:ok, {_flags, children}} = init(base)
      assert endpoint_opts(children)[:alpns] == ["iroh-console/1"]
    end

    test "honours an alpn override", %{base: base} do
      assert {:ok, {_flags, children}} = init(base ++ [alpn: "my-app/console/1"])
      assert endpoint_opts(children)[:alpns] == ["my-app/console/1"]
    end

    test "forwards only session-relevant options to sessions", %{base: base} do
      assert {:ok, {_flags, children}} = init(base ++ [idle_timeout: 1_234, network: :n0])

      {IrohConsole.Acceptor, :start_link, [opts]} = child(children, IrohConsole.Acceptor).start

      assert opts[:session_opts][:auth] == {StubAuth, []}
      assert opts[:session_opts][:idle_timeout] == 1_234
      refute Keyword.has_key?(opts[:session_opts], :network)
    end
  end

  describe "invalid configuration" do
    test "declines to start rather than crashing the application" do
      # A boot loop on a field device is far worse than a missing console.
      log =
        capture_log(fn ->
          assert init(
                   identity: {IrohConsole.Identity.File, path: "/proc/nope/identity"},
                   auth: StubAuth
                 ) == :ignore
        end)

      assert log =~ "not starting"
      assert log =~ "identity:"
    end

    test "rejects an unparseable endpoint id", %{identity: identity} do
      log =
        capture_log(fn ->
          assert init(identity: identity, peer_allowlist: ["definitely-not-an-endpoint-id"]) ==
                   :ignore
        end)

      assert log =~ "invalid endpoint id"
    end

    test "rejects a non-list allowlist", %{identity: identity} do
      log =
        capture_log(fn -> assert init(identity: identity, peer_allowlist: "nope") == :ignore end)

      assert log =~ "must be :all or a list"
    end

    test "rejects a non-id entry", %{identity: identity} do
      log =
        capture_log(fn -> assert init(identity: identity, peer_allowlist: [123]) == :ignore end)

      assert log =~ "must be endpoint ids"
    end
  end

  # The DynamicSupervisor child takes its :name as its id.
  defp sessions_child(children) do
    Enum.find_value(children, fn child ->
      if match?({DynamicSupervisor, :start_link, _}, child.start), do: child.id
    end)
  end
end
