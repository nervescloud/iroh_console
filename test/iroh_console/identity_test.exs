defmodule IrohConsole.IdentityTest do
  use ExUnit.Case, async: true

  alias IrohConsole.Identity

  setup do
    dir = Path.join(System.tmp_dir!(), "iroh_console_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  describe "File.fetch/1" do
    test "returns a file identity iroh_beam understands", %{dir: dir} do
      path = Path.join(dir, "identity")
      assert {:ok, {:file, ^path}} = Identity.File.fetch(path: path)
    end

    test "creates the parent directory", %{dir: dir} do
      path = Path.join([dir, "nested", "deeper", "identity"])
      assert {:ok, {:file, ^path}} = Identity.File.fetch(path: path)
      assert File.dir?(Path.dirname(path))
    end

    test "locks the directory down to the owner", %{dir: dir} do
      # The key is stored unencrypted, so this is the only thing protecting it
      # from other users on the device.
      path = Path.join(dir, "identity")
      assert {:ok, _} = Identity.File.fetch(path: path)
      assert {:ok, %File.Stat{mode: mode}} = File.stat(Path.dirname(path))
      assert Bitwise.band(mode, 0o077) == 0
    end

    test "leaves a pre-existing directory's permissions alone", %{dir: dir} do
      # The operator chose this directory; it may be shared, and it may not even
      # be ours to chmod. Nothing here should fail because of that.
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o755)

      assert {:ok, _} = Identity.File.fetch(path: Path.join(dir, "identity"))

      assert {:ok, %File.Stat{mode: mode}} = File.stat(dir)
      assert Bitwise.band(mode, 0o777) == 0o755
    end

    test "is idempotent", %{dir: dir} do
      path = Path.join(dir, "identity")
      assert {:ok, first} = Identity.File.fetch(path: path)
      assert {:ok, ^first} = Identity.File.fetch(path: path)
    end

    test "refuses rather than inventing a path when there is no data partition" do
      # No /data on the host, and falling back to a temp dir would look like it
      # worked while issuing a new identity on every boot.
      if Identity.File.default_path() == nil do
        assert {:error, message} = Identity.File.fetch([])
        assert message =~ "no identity path"
        assert message =~ "Configure an explicit path"
      else
        assert {:ok, {:file, _}} = Identity.File.fetch([])
      end
    end

    test "reports why it cannot prepare an unusable path" do
      assert {:error, message} = Identity.File.fetch(path: "/proc/nope/identity")
      assert message =~ "cannot prepare"
    end
  end

  describe "Ephemeral.fetch/1" do
    test "asks iroh_beam for a throwaway key" do
      assert {:ok, :ephemeral} = Identity.Ephemeral.fetch([])
    end
  end

  test "both adapters satisfy the behaviour" do
    assert Identity.behaviour_info(:callbacks) == [fetch: 1]
  end
end
