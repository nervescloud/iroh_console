defmodule IrohConsole.AuthTest do
  use ExUnit.Case, async: true

  alias IrohConsole.Auth

  describe "nonce/0" do
    test "is 256 bits" do
      assert byte_size(Auth.nonce()) == 32
    end

    test "does not repeat" do
      nonces = for _ <- 1..1_000, do: Auth.nonce()
      assert length(Enum.uniq(nonces)) == 1_000
    end
  end

  describe "secure_compare/2" do
    test "matches identical binaries" do
      secret = :crypto.strong_rand_bytes(32)
      assert Auth.secure_compare(secret, secret)
      assert Auth.secure_compare("", "")
    end

    test "rejects differing binaries" do
      refute Auth.secure_compare("abcdef", "abcdeg")
      refute Auth.secure_compare("abcdef", "zbcdef")
      refute Auth.secure_compare(<<0>>, <<1>>)
    end

    test "rejects differing lengths" do
      refute Auth.secure_compare("abc", "abcd")
      refute Auth.secure_compare("", "a")
    end

    test "agrees with ==/2 across random pairs" do
      for _ <- 1..500 do
        a = :crypto.strong_rand_bytes(:rand.uniform(48))
        b = if :rand.uniform(2) == 1, do: a, else: :crypto.strong_rand_bytes(:rand.uniform(48))
        assert Auth.secure_compare(a, b) == (a == b)
      end
    end
  end

  describe "None adapter" do
    test "waives the challenge" do
      assert IrohConsole.Auth.None.challenge(%{endpoint_id: :whatever}) == :skip
    end

    test "verifies anything, since it is never consulted after :skip" do
      assert IrohConsole.Auth.None.verify(%{endpoint_id: :whatever}, "n", "r") == :ok
    end

    test "satisfies the behaviour" do
      callbacks = Enum.sort(IrohConsole.Auth.behaviour_info(:callbacks))
      assert {:challenge, 1} in callbacks
      assert {:verify, 3} in callbacks
      # Optional, for adapters that need supervised state.
      assert IrohConsole.Auth.behaviour_info(:optional_callbacks) == [child_spec: 1]
    end
  end
end
