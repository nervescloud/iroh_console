defmodule IrohConsole.Auth.PasswordTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias IrohConsole.Auth.Password

  @password "correct horse battery staple"

  defp context(opts), do: %{endpoint_id: "peer", opts: opts}

  describe "verify/3" do
    test "accepts the configured password" do
      assert Password.verify(context(password: @password), "nonce", @password) == :ok
    end

    test "refuses anything else" do
      ctx = context(password: @password)
      assert Password.verify(ctx, "nonce", "wrong") == {:error, :wrong_password}
      assert Password.verify(ctx, "nonce", "") == {:error, :wrong_password}
    end

    test "refuses a near miss" do
      ctx = context(password: @password)
      # Off by one character, and by one trailing space.
      assert Password.verify(ctx, "n", @password <> " ") == {:error, :wrong_password}

      assert Password.verify(ctx, "n", String.slice(@password, 0..-2//1)) ==
               {:error, :wrong_password}
    end

    test "is not fooled by a correct prefix" do
      # secure_compare/2 checks length first and then every byte, so a prefix
      # is no closer to correct than anything else.
      ctx = context(password: @password)
      assert Password.verify(ctx, "n", "correct") == {:error, :wrong_password}
    end

    test "compares the whole string, including unicode" do
      ctx = context(password: "påsswörd-🔐")
      assert Password.verify(ctx, "n", "påsswörd-🔐") == :ok
      assert Password.verify(ctx, "n", "påsswörd-") == {:error, :wrong_password}
    end
  end

  describe "password_file" do
    setup do
      dir = Path.join(System.tmp_dir!(), "iroh_pw_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{path: Path.join(dir, "password")}
    end

    test "reads the password from disk", %{path: path} do
      File.write!(path, @password)
      assert Password.verify(context(password_file: path), "n", @password) == :ok
    end

    test "ignores the trailing newline `echo` leaves", %{path: path} do
      File.write!(path, @password <> "\n")
      assert Password.verify(context(password_file: path), "n", @password) == :ok
    end

    test "reports a missing file rather than failing open", %{path: path} do
      assert {:error, {:password_unreadable, ^path, :enoent}} =
               Password.verify(context(password_file: path), "n", "anything")
    end

    test "refuses an empty file", %{path: path} do
      File.write!(path, "\n")

      assert {:error, {:empty_password, _}} =
               Password.verify(context(password_file: path), "n", "")
    end
  end

  describe "configuration errors" do
    test "refuses when nothing is configured" do
      assert Password.verify(context([]), "n", "anything") == {:error, :no_password_configured}
    end

    test "refuses an empty password" do
      assert {:error, {:empty_password, :password}} =
               Password.verify(context(password: ""), "n", "")
    end

    test "refuses a non-binary password" do
      assert {:error, {:invalid_password, _, 12_345}} =
               Password.verify(context(password: 12_345), "n", "12345")
    end

    test "warns about a short password but still works" do
      log =
        capture_log(fn ->
          assert Password.verify(context(password: "hunter2"), "n", "hunter2") == :ok
        end)

      assert log =~ "shorter than"
    end

    test "says nothing about a long one" do
      log =
        capture_log(fn ->
          assert Password.verify(context(password: @password), "n", @password) == :ok
        end)

      refute log =~ "shorter than"
    end
  end

  describe "generate/0" do
    test "produces something long enough not to warn" do
      password = Password.generate()
      assert String.length(password) == 32

      log = capture_log(fn -> Password.verify(context(password: password), "n", password) end)
      refute log =~ "shorter than"
    end

    test "does not repeat" do
      passwords = for _ <- 1..500, do: Password.generate()
      assert length(Enum.uniq(passwords)) == 500
    end
  end

  describe "challenge/1" do
    test "issues a fresh nonce, keeping the wire protocol uniform" do
      assert {:ok, first} = Password.challenge(context([]))
      assert {:ok, second} = Password.challenge(context([]))
      assert byte_size(first) == 32
      assert first != second
    end
  end
end
