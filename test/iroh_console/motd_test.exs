defmodule IrohConsole.MOTDTest do
  use ExUnit.Case, async: true

  alias IrohConsole.MOTD

  # IrohBeam.Endpoint.addr/1 is a GenServer.call(endpoint, :addr), and
  # IrohConsole.Server derives the endpoint name from the server name — so a stub
  # registered under that derived name exercises the success path without an
  # endpoint, a relay or a network.
  defmodule FakeEndpoint do
    @moduledoc false
    use GenServer

    # The addr is passed in rather than built here: a real EndpointAddr is
    # needed, since EndpointTicket.new/1 rejects a lookalike map — which is
    # exactly the difference show: :ticket depends on.
    def start_link({server_name, addr}) do
      GenServer.start_link(__MODULE__, addr, name: IrohConsole.Server.endpoint(server_name))
    end

    @impl true
    def init(addr), do: {:ok, addr}

    @impl true
    def handle_call(:addr, _from, addr), do: {:reply, {:ok, addr}, addr}
  end

  defp with_fake_endpoint(name) do
    {:ok, secret_key} = IrohBeam.SecretKey.generate()
    {:ok, id} = IrohBeam.SecretKey.endpoint_id(secret_key)

    {:ok, addr} =
      IrohBeam.EndpointAddr.new(id, relay_urls: ["https://relay.example.com"], ip_addrs: [])

    start_supervised!(%{id: name, start: {FakeEndpoint, :start_link, [{name, addr}]}})
    to_string(id)
  end

  describe "shape" do
    test "is a list of rows, each a list of cells" do
      # NervesMOTD: extra_rows :: [row()], row :: [cell()], cell :: {label, value}.
      # A bare [{label, value}] would be two rows of one cell and render wrong.
      assert [[{label, value}]] = MOTD.rows()
      assert is_binary(label)
      assert is_binary(value)
    end
  end

  describe "when the console is not running" do
    test "says so rather than exiting" do
      assert [[{"iroh id", "not running"}]] = MOTD.rows(server: NoSuchServer)
    end

    test "honours a custom label" do
      assert [[{"console", "not running"}]] = MOTD.rows(server: NoSuchServer, label: "console")
    end

    test "reports it for a ticket too" do
      assert [[{"iroh ticket", "not running"}]] = MOTD.rows(server: NoSuchServer, show: :ticket)
    end
  end

  describe "when the endpoint answers" do
    setup do
      name = IrohConsole.MOTDTest.Server
      %{server: name, id: with_fake_endpoint(name)}
    end

    test "shows the endpoint id in full by default", %{server: server, id: id} do
      assert [[{"iroh id", ^id}]] = MOTD.rows(server: server)
      assert String.length(id) == 64
    end

    test "the default value is an id, and an id cannot be connected with", %{id: id} do
      # The whole reason :show exists. Pasting this into the connect command
      # fails, because address lookup is off and nothing can turn an id into a
      # location.
      assert {:ok, _} = IrohBeam.EndpointId.parse(id)
      assert {:error, _} = IrohBeam.EndpointTicket.parse(id)
    end

    test "labels say which value it is", %{server: server} do
      assert [[{"iroh id", _}]] = MOTD.rows(server: server)
      assert [[{"iroh ticket", _}]] = MOTD.rows(server: server, show: :ticket)
    end

    test "labels fit the 12 characters NervesMOTD allows", %{server: server} do
      for show <- [:id, :ticket] do
        assert [[{label, _}]] = MOTD.rows(server: server, show: show)
        assert String.length(label) <= 12
      end
    end

    test "truncates when asked", %{server: server, id: id} do
      assert [[{"iroh id", value}]] = MOTD.rows(server: server, truncate: 16)
      assert value == String.slice(id, 0, 16) <> "…"
      assert String.starts_with?(id, String.slice(value, 0, 16))
    end

    test "does not truncate an id shorter than the limit", %{server: server, id: id} do
      assert [[{_, value}]] = MOTD.rows(server: server, truncate: 500)
      assert value == id
    end

    test "ignores a nonsensical truncate", %{server: server, id: id} do
      for bad <- [false, nil, 0, -5, "16"] do
        assert [[{_, ^id}]] = MOTD.rows(server: server, truncate: bad)
      end
    end

    test "show: :ticket yields something that parses as a ticket", %{server: server, id: id} do
      assert [[{"iroh ticket", value}]] = MOTD.rows(server: server, show: :ticket)
      assert {:ok, _ticket} = IrohBeam.EndpointTicket.parse(value)
      # And is meaningfully longer than the id, which is why it is not default.
      assert String.length(value) > String.length(id)
    end

    test "the full line fits the width NervesMOTD gives a single-cell row", %{server: server} do
      # format_row([{label, value}]) is ["  ", label padded to 12, " : ", value].
      [[{label, value}]] = MOTD.rows(server: server)
      assert 2 + max(String.length(label), 12) + 3 + String.length(value) == 81
    end
  end
end
