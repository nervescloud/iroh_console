defmodule Mix.Tasks.IrohConsole.Gen.Secret do
  @shortdoc "Generates a TOTP secret for a device"

  @moduledoc """
  Generates a TOTP secret, and the `otpauth://` URI to enrol it.

      mix iroh_console.gen.secret --account device-1234

  ## Options

    * `--account NAME` — what the authenticator app will call it. Required.
    * `--issuer NAME` — defaults to `IrohConsole`
    * `--out PATH` — also write the secret to a file, in the form
      `IrohConsole.Auth.TOTP`'s `:secret_path` expects

  ## Give each device its own

  The device stores a secret that *verifies* codes, so anyone who extracts
  firmware from one device can generate codes for every device sharing that
  secret. Generate one per device.
  """

  use Mix.Task

  alias IrohConsole.Auth.TOTP

  @requirements ["app.config"]

  @switches [account: :string, issuer: :string, out: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: @switches)

    account =
      Keyword.get(opts, :account) ||
        Mix.raise("--account is required, e.g. --account device-1234")

    issuer = Keyword.get(opts, :issuer, "IrohConsole")

    {:ok, _apps} = Application.ensure_all_started(:iroh_console)

    secret = TOTP.generate_secret()
    encoded = Base.encode32(secret, padding: false)

    case Keyword.get(opts, :out) do
      nil -> :ok
      path -> write_secret!(path, encoded)
    end

    Mix.shell().info("""

    secret (base32): #{encoded}

    enrol with:      #{TOTP.provisioning_uri(secret, issuer, account)}

    On the device:

        auth: {IrohConsole.Auth.TOTP, secret_base32: "#{encoded}"}

    or point :secret_path at a file containing that base32 string.
    """)
  end

  defp write_secret!(path, encoded) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, encoded)
    # The secret verifies codes, so it is as sensitive as a password file.
    File.chmod!(path, 0o600)
    Mix.shell().info("wrote #{path} (mode 0600)")
  end
end
