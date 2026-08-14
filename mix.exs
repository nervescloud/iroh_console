defmodule IrohConsole.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nervescloud/iroh_console"

  def project do
    [
      app: :iroh_console,
      version: @version,
      # Set by iroh_beam 0.2.0, which declares "~> 1.20". Our own code has no
      # such requirement, so this can widen if that floor is ever relaxed —
      # relevant for Nerves projects, which lag the newest Elixir more often
      # than not.
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "Remote IEx console for Nerves devices over an iroh peer-to-peer connection",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      # :iex is required — ExTTY starts a real IEx shell, and :iex.start/2
      # fails with {:error, :terminated} if the application is not running.
      extra_applications: [:logger, :iex],
      mod: {IrohConsole.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # Shell emulation as a process. Same library nerves_hub_link uses for its
      # device console, adapted from OTP's ssh_cli.erl.
      {:extty, "~> 0.4"},
      # iroh endpoint, relays and streams.
      {:iroh_beam, "~> 0.2.0"},
      # RFC 6238, including the reuse prevention the RFC requires.
      {:nimble_totp, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end
end
