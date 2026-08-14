defmodule Mix.Tasks.IrohConsole.Gen.Script do
  @shortdoc "Generates the bin/iroh-console wrapper into this project"

  @moduledoc """
  Writes an executable `bin/iroh-console` into the current project.

      mix iroh_console.gen.script

  ## Options

    * `--path PATH` — where to write it. Defaults to `bin/iroh-console`.
    * `--force` — overwrite without asking.

  ## Why this exists

  `mix iroh_console.connect` works on its own, but the terminal stays in cooked
  mode: input reaches the device only when you press Enter, rather than as you
  type. Raw mode has to be set by the shell *before* the VM starts, because port
  children are forked from `erl_child_setup` with no controlling terminal, so
  the BEAM cannot do it for itself.

  This library ships that wrapper, but a script inside `deps/` is not something
  anyone should be expected to run. Generating a copy into your own project puts
  it where the rest of your tooling lives, and lets you commit it.

  The generated script also prompts for the TOTP code before enabling raw mode —
  once the terminal is raw there is no echo and Enter sends CR rather than LF, so
  an interactive prompt from inside the VM cannot behave properly.
  """

  use Mix.Task

  @requirements ["app.config"]

  @default_path "bin/iroh-console"

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: [path: :string, force: :boolean])
    path = Keyword.get(opts, :path, @default_path)

    {:ok, _apps} = Application.ensure_all_started(:iroh_console)

    Mix.Generator.create_file(path, template(), force: Keyword.get(opts, :force, false))

    # Pointless without this, and Hex does not preserve the executable bit.
    File.chmod!(path, 0o755)

    Mix.shell().info("""

    Run a console with:

        #{path} TICKET

    Any further arguments are passed through to `mix iroh_console.connect`.
    """)
  end

  defp template do
    :iroh_console
    |> :code.priv_dir()
    |> Path.join("templates/iroh-console.sh")
    |> File.read!()
  end
end
