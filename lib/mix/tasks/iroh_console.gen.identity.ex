defmodule Mix.Tasks.IrohConsole.Gen.Identity do
  @shortdoc "Creates an iroh identity file and prints its endpoint id"

  @moduledoc """
  Writes an identity to a path, and prints the endpoint id it carries.

      mix iroh_console.gen.identity priv/iroh_console.identity

  ## What it is for

  A client that connects without one is a different endpoint on every run, so
  nothing on the far side can name it — there is nothing to put in an allowlist
  and nothing to register. This writes a key that stays put, and tells you the
  name it answers to.

  ## It will not replace one

  Run against a path that already holds an identity, this reads it and prints
  its endpoint id, changing nothing. Overwriting would retire a name that
  allowlists and control-plane records still point at, and since the private
  bytes are not meant to be read, the endpoint id is the only sign that the key
  underneath had changed.

  To roll an identity deliberately, delete the file and run this again.

  ## The file

  The 32 private key bytes, unencrypted, written `0600` — anyone who can read it
  can be this endpoint. On a device, prefer a path that survives a firmware
  update; `IrohConsole.Identity.File` explains where that is and why.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {_opts, args} = OptionParser.parse!(argv, strict: [])

    path =
      case args do
        [path] ->
          path

        [] ->
          Mix.raise(
            "a path is required, e.g. mix iroh_console.gen.identity priv/iroh_console.identity"
          )

        _several ->
          Mix.raise("one identity at a time: #{Enum.join(args, " ")}")
      end

    {:ok, _apps} = Application.ensure_all_started(:iroh_console)

    # Asked before the identity is read, because reading it is what creates one.
    existing? = File.exists?(path)

    case IrohConsole.Identity.File.endpoint_id(path) do
      {:ok, endpoint_id} -> report(path, endpoint_id, existing?)
      {:error, reason} -> Mix.raise("could not write an identity to #{path}: #{reason}")
    end
  end

  defp report(path, endpoint_id, existing?) do
    Mix.shell().info("""

    #{if existing?, do: "#{path} already held an identity", else: "wrote #{path} (mode 0600)"}

    endpoint id: #{endpoint_id}

    On the device:

        identity: {IrohConsole.Identity.File, path: "#{path}"}
    """)
  end
end
