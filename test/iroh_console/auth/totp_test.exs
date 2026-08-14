defmodule IrohConsole.Auth.TOTPTest do
  # Not async: the replay tracker is a singleton ETS table.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias IrohConsole.Auth.TOTP
  alias IrohConsole.Auth.TOTP.Replay

  setup do
    case start_supervised(Replay) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    secret = TOTP.generate_secret()
    %{secret: secret, context: %{endpoint_id: "peer", opts: [secret: secret]}}
  end

  defp code(secret, offset \\ 0),
    do: NimbleTOTP.verification_code(secret, time: System.os_time(:second) + offset)

  describe "verify/3" do
    test "accepts the current code", %{secret: secret, context: context} do
      assert TOTP.verify(context, "nonce", code(secret)) == :ok
    end

    test "tolerates a code from the neighbouring period", %{secret: secret, context: context} do
      # A device without an RTC will not agree with the operator to the second.
      assert TOTP.verify(context, "nonce", code(secret, -30)) == :ok
    end

    test "refuses a code well outside the drift window", %{secret: secret, context: context} do
      assert TOTP.verify(context, "nonce", code(secret, -600)) == {:error, :invalid_code}
    end

    test "honours a wider drift setting", %{secret: secret} do
      context = %{endpoint_id: "peer", opts: [secret: secret, drift: 4]}
      assert TOTP.verify(context, "nonce", code(secret, -120)) == :ok
    end

    test "refuses nonsense", %{context: context} do
      assert TOTP.verify(context, "nonce", "000000") == {:error, :invalid_code}
      assert TOTP.verify(context, "nonce", "") == {:error, :invalid_code}
      assert TOTP.verify(context, "nonce", "not-a-code") == {:error, :invalid_code}
    end

    test "ignores surrounding whitespace", %{secret: secret, context: context} do
      assert TOTP.verify(context, "nonce", "  #{code(secret)}\n") == :ok
    end
  end

  describe "reuse" do
    test "refuses a code that has already been accepted", %{secret: secret, context: context} do
      current = code(secret)
      assert TOTP.verify(context, "nonce", current) == :ok

      # RFC 6238 §5.2: a verifier must accept a given code only once.
      assert TOTP.verify(context, "another-nonce", current) == {:error, :invalid_code}
    end

    test "tracks secrets separately" do
      one = TOTP.generate_secret()
      two = TOTP.generate_secret()

      assert TOTP.verify(%{endpoint_id: "a", opts: [secret: one]}, "n", code(one)) == :ok
      # Burning a code for one device must not lock out another.
      assert TOTP.verify(%{endpoint_id: "b", opts: [secret: two]}, "n", code(two)) == :ok
    end
  end

  describe "secret sources" do
    test "accepts base32 as authenticator apps display it", %{secret: secret} do
      encoded = Base.encode32(secret, padding: false)
      context = %{endpoint_id: "peer", opts: [secret_base32: encoded]}
      assert TOTP.verify(context, "nonce", code(secret)) == :ok
    end

    test "accepts lowercase base32", %{secret: secret} do
      encoded = secret |> Base.encode32(padding: false) |> String.downcase()
      context = %{endpoint_id: "peer", opts: [secret_base32: encoded]}
      assert TOTP.verify(context, "nonce", code(secret)) == :ok
    end

    test "reads base32 from a file, ignoring a trailing newline", %{secret: secret} do
      path = Path.join(System.tmp_dir!(), "totp_#{System.unique_integer([:positive])}")
      File.write!(path, Base.encode32(secret, padding: false) <> "\n")
      on_exit(fn -> File.rm(path) end)

      context = %{endpoint_id: "peer", opts: [secret_path: path]}
      assert TOTP.verify(context, "nonce", code(secret)) == :ok
    end

    test "reports a missing secret file" do
      context = %{endpoint_id: "peer", opts: [secret_path: "/nope/missing"]}
      assert {:error, {:secret_unreadable, _, :enoent}} = TOTP.verify(context, "n", "123456")
    end

    test "reports base32 that will not decode" do
      context = %{endpoint_id: "peer", opts: [secret_base32: "not!valid!base32"]}
      assert TOTP.verify(context, "n", "123456") == {:error, :secret_not_base32}
    end

    test "reports no secret at all" do
      assert TOTP.verify(%{endpoint_id: "peer", opts: []}, "n", "123456") ==
               {:error, :no_secret_configured}
    end
  end

  describe "safety rails" do
    test "refuses to verify when reuse cannot be tracked", %{secret: secret, context: context} do
      # Failing open here would silently drop an RFC requirement.
      stop_supervised!(Replay)

      log =
        capture_log(fn ->
          assert TOTP.verify(context, "nonce", code(secret)) ==
                   {:error, :replay_tracker_unavailable}
        end)

      assert log =~ "replay tracker is not running"
    end
  end

  describe "enrolment helpers" do
    test "generates a 20-byte secret" do
      assert byte_size(TOTP.generate_secret()) == 20
    end

    test "builds a scannable otpauth uri", %{secret: secret} do
      uri = TOTP.provisioning_uri(secret, "NervesCloud", "device-1234")
      assert uri =~ "otpauth://totp/NervesCloud:device-1234"
      assert uri =~ "issuer=NervesCloud"
    end
  end

  describe "challenge/1" do
    test "issues a fresh nonce even though TOTP does not need one", %{context: context} do
      # Keeps the wire protocol uniform across adapters.
      assert {:ok, first} = TOTP.challenge(context)
      assert {:ok, second} = TOTP.challenge(context)
      assert byte_size(first) == 32
      assert first != second
    end
  end
end
