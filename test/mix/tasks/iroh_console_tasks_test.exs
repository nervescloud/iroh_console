defmodule Mix.Tasks.IrohConsoleTasksTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.IrohConsole.Connect
  alias Mix.Tasks.IrohConsole.EndpointId
  alias Mix.Tasks.IrohConsole.Gen

  import ExUnit.CaptureIO, only: [capture_io: 1]

  @endpoint_id ~r/\b[0-9a-f]{64}\b/

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

  describe "gen.identity" do
    test "writes an identity and prints the endpoint id it carries" do
      path = tmp_path()

      output = capture_io(fn -> Gen.Identity.run([path]) end)

      assert File.exists?(path)
      assert [endpoint_id] = Regex.run(@endpoint_id, output)
      # The id names the key on disk, rather than being minted for the message.
      assert IrohConsole.Identity.File.endpoint_id(path) == {:ok, endpoint_id}
    end

    test "writes it owner-only" do
      path = tmp_path()

      capture_io(fn -> Gen.Identity.run([path]) end)

      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o077) == 0
    end

    test "reads an identity that is already there rather than replacing it" do
      path = tmp_path()
      first = capture_io(fn -> Gen.Identity.run([path]) end)
      key = File.read!(path)

      second = capture_io(fn -> Gen.Identity.run([path]) end)

      # A new key here would retire a name that allowlists and control-plane
      # records still point at, and nothing on screen would say so.
      assert File.read!(path) == key
      assert second =~ "already held an identity"
      assert Regex.run(@endpoint_id, second) == Regex.run(@endpoint_id, first)
    end

    test "asks for a path rather than choosing one" do
      assert_raise Mix.Error, ~r/path is required/, fn -> Gen.Identity.run([]) end
    end
  end

  describe "endpoint_id" do
    test "prints the id and nothing else" do
      path = tmp_path()
      capture_io(fn -> Gen.Identity.run([path]) end)

      output = capture_io(fn -> EndpointId.run([path]) end)

      assert String.trim(output) =~ ~r/^[0-9a-f]{64}$/
    end

    test "refuses a path holding no identity rather than creating one" do
      path = tmp_path()

      # A typo would otherwise answer confidently with the name of a key nobody
      # has, while the real identity sat where it always was.
      assert_raise Mix.Error, ~r/no identity/, fn -> EndpointId.run([path]) end
      refute File.exists?(path)
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

  # A fresh directory per test, so an identity written by one is never the one
  # another reads.
  defp tmp_path do
    dir = Path.join(System.tmp_dir!(), "iroh_identity_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    Path.join(dir, "identity")
  end
end
