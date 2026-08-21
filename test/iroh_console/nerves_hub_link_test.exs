defmodule IrohConsole.NervesHubLinkTest do
  use ExUnit.Case, async: true

  alias IrohConsole.NervesHubLink

  # Same stand-in as the MOTD and NervesHub tests: IrohBeam.Endpoint.addr/1 is a
  # GenServer.call(endpoint, :addr), and Server.endpoint/1 derives the name.
  defmodule FakeEndpoint do
    @moduledoc false
    use GenServer

    def start_link({server_name, reply}) do
      GenServer.start_link(__MODULE__, reply, name: IrohConsole.Server.endpoint(server_name))
    end

    @impl true
    def init(reply), do: {:ok, reply}

    @impl true
    def handle_call(:addr, _from, reply), do: {:reply, reply, reply}
  end

  defp with_fake_endpoint(name, relay_urls \\ ["https://relay.example.com"]) do
    {:ok, secret_key} = IrohBeam.SecretKey.generate()
    {:ok, id} = IrohBeam.SecretKey.endpoint_id(secret_key)
    {:ok, addr} = IrohBeam.EndpointAddr.new(id, relay_urls: relay_urls, ip_addrs: [])

    start_supervised!(%{id: name, start: {FakeEndpoint, :start_link, [{name, {:ok, addr}}]}})

    to_string(id)
  end

  defp put_server(name) do
    Application.put_env(:iroh_console, :nerves_hub_link, server: name)
    on_exit(fn -> Application.delete_env(:iroh_console, :nerves_hub_link) end)
  end

  describe "with a running console" do
    setup do
      name = IrohConsole.NervesHubLinkTest.Server
      put_server(name)
      %{server: name, id: with_fake_endpoint(name)}
    end

    test "reports the endpoint id as the identity", %{id: id} do
      assert {:ok, identity} = NervesHubLink.identity()

      assert identity.service == "iroh"
      assert identity.identifier == id
      assert String.length(identity.identifier) == 64
    end

    test "names its instance, so an application's own endpoint can coexist" do
      # Both would be service "iroh". Without distinct instances the second one
      # reported would overwrite the first.
      assert {:ok, %{instance: "iroh_console"}} = NervesHubLink.identity()
    end

    test "the instance is stable across reports" do
      # NervesHub keys the identity on it, so an instance derived from anything
      # that changes would create a new record instead of updating.
      assert {:ok, first} = NervesHubLink.identity()
      assert {:ok, second} = NervesHubLink.identity()

      assert first.instance == second.instance
    end

    test "the identifier is an id, which cannot be dialled on its own" do
      # The whole reason the ticket is carried separately.
      assert {:ok, identity} = NervesHubLink.identity()

      assert {:ok, _} = IrohBeam.EndpointId.parse(identity.identifier)
      assert {:error, _} = IrohBeam.EndpointTicket.parse(identity.identifier)
    end

    test "carries a connectable ticket in the details" do
      assert {:ok, %{details: details}} = NervesHubLink.identity()

      assert {:ok, _ticket} = IrohBeam.EndpointTicket.parse(details["ticket"])
    end

    test "the ticket and the identifier are not the same value", %{id: id} do
      assert {:ok, identity} = NervesHubLink.identity()

      refute identity.details["ticket"] == id
      assert String.length(identity.details["ticket"]) > String.length(id)
    end

    test "carries the relay the device is currently using" do
      # iroh normalizes relay URLs, which includes adding the trailing slash.
      assert {:ok, %{details: details}} = NervesHubLink.identity()

      assert details["relay_urls"] == ["https://relay.example.com/"]
    end

    test "does not report direct addresses separately from the ticket" do
      # They are already inside the ticket and change constantly; repeating them
      # would make every reconnect look like a change to NervesHub.
      assert {:ok, %{details: details}} = NervesHubLink.identity()

      assert Map.keys(details) |> Enum.sort() == ["relay_urls", "ticket"]
    end

    test "the payload is the shape NervesHubLink asks a provider for" do
      assert {:ok, identity} = NervesHubLink.identity()

      assert is_binary(identity.service)
      assert is_binary(identity.identifier)
      assert is_map(identity.details)
    end

    test "the details are wire-safe primitives, well inside NervesHub's size cap" do
      # These are serialized to msgpack or JSON on the way out and stored as
      # jsonb, so every value has to be a plain string or list of them. NervesHub
      # rejects a details payload over 4KB once encoded.
      assert {:ok, %{details: details}} = NervesHubLink.identity()

      assert is_binary(details["ticket"])
      assert Enum.all?(details["relay_urls"], &is_binary/1)

      encoded_size =
        Enum.reduce(details, 0, fn {key, value}, acc ->
          acc + byte_size(key) + IO.iodata_length(List.wrap(value))
        end)

      assert encoded_size < 4_096
    end
  end

  describe "with no console running" do
    test "is unavailable rather than an error" do
      # A device where the console isn't configured, or hasn't started yet,
      # reconnects like any other. Reporting that as an error would produce a
      # warning on every connection.
      put_server(IrohConsole.NervesHubLinkTest.NotStarted)

      assert NervesHubLink.identity() == :unavailable
    end

    test "defaults to IrohConsole.Server when nothing is configured" do
      assert NervesHubLink.identity() == :unavailable
    end
  end

  describe "when the endpoint fails for another reason" do
    setup do
      name = IrohConsole.NervesHubLinkTest.BrokenServer
      put_server(name)

      start_supervised!(%{
        id: name,
        start: {FakeEndpoint, :start_link, [{name, {:error, :something_else}}]}
      })

      :ok
    end

    test "passes the reason through so it is logged as a warning" do
      assert NervesHubLink.identity() == {:error, :something_else}
    end
  end
end
