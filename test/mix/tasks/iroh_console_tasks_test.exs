defmodule Mix.Tasks.IrohConsoleTasksTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.IrohConsole.Connect

  describe "build_network/1" do
    test "defaults to n0 when no relay is given" do
      assert Connect.build_network([]) == {:ok, :n0}
    end

    test "builds a custom network from one relay" do
      assert {:ok, {:custom, [relay]}} =
               Connect.build_network(relay: "https://iroh.nervescloud.com")

      # iroh_beam normalises the URL, appending a trailing slash.
      assert IrohBeam.Relay.url(relay) == "https://iroh.nervescloud.com/"
    end

    test "keeps several relays in the order given" do
      assert {:ok, {:custom, relays}} =
               Connect.build_network(
                 relay: "https://one.example.com",
                 relay: "https://two.example.com"
               )

      assert Enum.map(relays, &IrohBeam.Relay.url/1) ==
               ["https://one.example.com/", "https://two.example.com/"]
    end

    test "reports an unusable relay url rather than failing later" do
      assert {:error, {:bad_relay, "not a url", _}} = Connect.build_network(relay: "not a url")
    end
  end

  describe "describe/1" do
    test "explains the failures an operator will actually hit" do
      assert Connect.describe({:bad_ticket, "junk"}) =~ "endpoint ticket"
      assert Connect.describe({:refused, "authentication failed"}) =~ "refused"
      assert Connect.describe(:not_a_terminal) =~ "interactive shell"
      assert Connect.describe(:handshake_timeout) =~ "handshake"
      assert Connect.describe(:eof) =~ "closed"
    end

    test "falls back to something readable for anything else" do
      assert Connect.describe({:weird, :thing}) =~ "could not connect"
    end
  end

  describe "gen.secret" do
    test "writes a base32 secret the TOTP adapter accepts" do
      dir = Path.join(System.tmp_dir!(), "iroh_secret_#{System.unique_integer([:positive])}")
      path = Path.join(dir, "totp.secret")
      on_exit(fn -> File.rm_rf(dir) end)

      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.IrohConsole.Gen.Secret.run(["--account", "device-1", "--out", path])
      end)

      encoded = File.read!(path)
      assert {:ok, secret} = Base.decode32(encoded, padding: false)
      assert byte_size(secret) == 20

      # Round-trips through the adapter that will consume it.
      context = %{endpoint_id: "peer", opts: [secret_path: path]}
      code = NimbleTOTP.verification_code(secret)

      start_supervised!(IrohConsole.Auth.TOTP.Replay)
      assert IrohConsole.Auth.TOTP.verify(context, "nonce", code) == :ok
    end

    test "writes the secret owner-only" do
      dir = Path.join(System.tmp_dir!(), "iroh_secret_#{System.unique_integer([:positive])}")
      path = Path.join(dir, "totp.secret")
      on_exit(fn -> File.rm_rf(dir) end)

      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.IrohConsole.Gen.Secret.run(["--account", "device-1", "--out", path])
      end)

      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o077) == 0
    end
  end
end
