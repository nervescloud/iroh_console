defmodule IrohConsole.MOTD do
  @moduledoc """
  A row for [NervesMOTD](https://hex.pm/packages/nerves_motd), showing this
  device's endpoint id or its ticket.

      # config/target.exs
      config :nerves_motd, extra_rows: {IrohConsole.MOTD, :rows, []}

  Which prints:

      iroh id : e13b243e722075ed7d40b6e7781efcb52ac4d69536c56b514c311327e47ff899

  ## Which value you want

  These are different things, and only one of them can be connected with:

    * the **endpoint id** — 64 hex characters, the device's public key. It says
      *who*, and it is what `:peer_allowlist` takes. It is **not** enough to dial
      with: address lookup is off, so nothing can turn an id into a location.
      Passing it to `mix iroh_console.connect` fails with "that does not look
      like an endpoint ticket".

    * the **ticket** — base32, typically 120 to 170 characters, carrying the id
      *and* the relay URLs *and* any direct addresses. This is what
      `bin/iroh-console` takes.

  The id is the default because it is the value you look up repeatedly, for an
  allowlist. Pass `show: :ticket` if you would rather have the thing you paste
  into a connect command — at the cost of a much longer line.

  ## Options

  Passed as the args of the MFA tuple, so they arrive as `rows/1`'s argument:

      config :nerves_motd, extra_rows: {IrohConsole.MOTD, :rows, [[truncate: 16]]}

    * `:show` — `:id` (default) or `:ticket`. See above; they are not
      interchangeable.
    * `:server` — which `IrohConsole.Server` to ask. Defaults to
      `IrohConsole.Server`, matching that module's own default name.
    * `:label` — the row label. Defaults to `"iroh id"` or `"iroh ticket"`
      depending on `:show`. NervesMOTD fits labels to 12 characters.
    * `:truncate` — show only the first N characters, followed by an ellipsis.
      Defaults to `false`.

  ## Why it is not truncated by default

  The id is 64 characters. NervesMOTD renders a single-cell row at full width
  without clipping — only two-column rows are cut to 24 — so the line comes to
  81 characters including the padded label and separator. That is one over a
  strict 80-column terminal.

  Showing it in full is still the better default: the whole point is to be able
  to copy it into an allowlist, and an id you cannot copy is decoration. Pass
  `truncate: 16` if you would rather have the tidy line.

  ## When the console is not up

  The value becomes `"not running"` if no server is started under that name, or
  `"offline"` if it is started but the endpoint has not come online yet. Both are
  ordinary during boot, and distinguishing them is the difference between "I
  forgot to add it to my supervision tree" and "the network is not up".
  """

  @default_labels %{id: "iroh id", ticket: "iroh ticket"}

  @typedoc "One NervesMOTD row: a list of `{label, value}` cells."
  @type row :: [{String.t(), String.t()}]

  @doc """
  Rows for `:extra_rows`.

  Returns a list containing a single row, itself a list of one cell — the
  nesting NervesMOTD expects, where a row may hold one or two cells.
  """
  @spec rows(keyword()) :: [row()]
  def rows(opts \\ []) do
    show = Keyword.get(opts, :show, :id)
    label = Keyword.get(opts, :label, Map.fetch!(@default_labels, show))
    server = Keyword.get(opts, :server, IrohConsole.Server)

    [[{label, value(show, server, opts)}]]
  end

  defp value(:id, server, opts) do
    server |> IrohConsole.Server.addr() |> render(& &1.id, opts)
  end

  defp value(:ticket, server, opts) do
    server |> IrohConsole.Server.ticket() |> render(& &1, opts)
  end

  defp render({:ok, value}, extract, opts) do
    value |> extract.() |> to_string() |> truncate(Keyword.get(opts, :truncate, false))
  end

  defp render({:error, :not_running}, _extract, _opts), do: "not running"
  defp render({:error, _reason}, _extract, _opts), do: "offline"

  defp truncate(id, length) when is_integer(length) and length > 0 and byte_size(id) > length,
    do: String.slice(id, 0, length) <> "…"

  defp truncate(id, _length), do: id
end
