defmodule IrohConsole.Application do
  # Deliberately empty. A console belongs in the host application's supervision
  # tree, under its own configuration, not started implicitly by adding this as
  # a dependency — see IrohConsole.Server.
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: IrohConsole.Supervisor)
  end
end
