defmodule Mix.Tasks.IrohConsole.EndpointId do
  @shortdoc "Prints the endpoint id of an identity file"

  @moduledoc """
  Prints the endpoint id an identity file carries, and nothing else.

      mix iroh_console.endpoint_id priv/iroh_console.identity

  Bare output, so it can be piped or copied straight into whatever wants the
  name — an allowlist, a control plane, a colleague.

  ## It will not create one

  A path with no identity at it is an error rather than an invitation. Asking
  what name a key has should not mint a new one: a mistyped path would
  otherwise answer confidently with an id that names a key nobody has, and the
  real one would go on sitting where it always was.

  Use `mix iroh_console.gen.identity` to write one.
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
            "a path is required, e.g. mix iroh_console.endpoint_id priv/iroh_console.identity"
          )

        _several ->
          Mix.raise("one identity at a time: #{Enum.join(args, " ")}")
      end

    File.exists?(path) ||
      Mix.raise("no identity at #{path}. Write one with: mix iroh_console.gen.identity #{path}")

    {:ok, _apps} = Application.ensure_all_started(:iroh_console)

    case IrohConsole.Identity.File.endpoint_id(path) do
      {:ok, endpoint_id} -> Mix.shell().info(endpoint_id)
      {:error, reason} -> Mix.raise("could not read the identity at #{path}: #{reason}")
    end
  end
end
