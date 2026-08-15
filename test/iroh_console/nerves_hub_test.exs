defmodule IrohConsole.NervesHubTest do
  use ExUnit.Case, async: true

  alias IrohConsole.NervesHub

  # Same stand-in as the MOTD tests: IrohBeam.Endpoint.addr/1 is a
  # GenServer.call(endpoint, :addr), and Server.endpoint/1 derives the name.
  defmodule FakeEndpoint do
    @moduledoc false
    use GenServer

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

  describe "with a running console" do
    setup do
      name = IrohConsole.NervesHubTest.Server
      %{server: name, id: with_fake_endpoint(name)}
    end

    test "ticket/1 returns a string that parses as a ticket", %{server: server} do
      value = NervesHub.ticket(server: server)

      # The health report requires string values, and the point of publishing it
      # is that an operator can paste it into a connect command.
      assert is_binary(value)
      assert {:ok, _ticket} = IrohBeam.EndpointTicket.parse(value)
    end

    test "endpoint_id/1 returns the id as a string", %{server: server, id: id} do
      assert NervesHub.endpoint_id(server: server) == id
      assert {:ok, _} = IrohBeam.EndpointId.parse(id)
    end

    test "the two are not interchangeable", %{server: server} do
      # An id cannot be connected with, which is why both are published.
      assert {:error, _} =
               [server: server] |> NervesHub.endpoint_id() |> IrohBeam.EndpointTicket.parse()
    end
  end

  describe "with no console running" do
    test "both report it as a string rather than raising" do
      # NervesHubLink calls these while building a report; an exception here
      # would take out the whole report, not just this field.
      assert NervesHub.ticket(server: NotStarted) == "not running"
      assert NervesHub.endpoint_id(server: NotStarted) == "not running"
    end

    test "zero-arity forms work, since config passes empty args" do
      # {IrohConsole.NervesHub, :ticket, []} calls ticket/0.
      assert is_binary(NervesHub.ticket())
      assert is_binary(NervesHub.endpoint_id())
    end
  end

  describe "the shape NervesHubLink expects" do
    test "an MFA tuple with these functions resolves to a string" do
      # DefaultReport does `vof({mod, fun, args}) -> apply(mod, fun, args)` for
      # each metadata value, then requires %{String.t() => String.t()}.
      metadata = %{
        "iroh_ticket" => {NervesHub, :ticket, []},
        "iroh_endpoint_id" => {NervesHub, :endpoint_id, []}
      }

      resolved =
        Map.new(metadata, fn
          {key, {mod, fun, args}} -> {to_string(key), apply(mod, fun, args)}
          {key, value} -> {to_string(key), value}
        end)

      assert Enum.all?(resolved, fn {k, v} -> is_binary(k) and is_binary(v) end)
    end
  end
end
