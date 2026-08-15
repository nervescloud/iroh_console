# Using with Nerves devices

A walkthrough for putting a console on one or two personal Nerves devices — a
Pi on your desk, another at a relative's house — and connecting to them from
your laptop from anywhere.

By the end you will have a device you can reach with:

```bash
bin/iroh-console <ticket>
```

and an IEx prompt on it, with no port forwarding, no VPN, and no static address.

## Before you start

You need a way to get a prompt on the device **once**, to read its ticket and
write its credential. Serial console, `ssh nerves.local`, NervesHub's console —
whatever you already use. After that first time you will not need it.

You also need the device to have working outbound internet. That is all: iroh
dials out, so nothing needs to accept inbound connections.

## 1. Add the dependency

In your Nerves project's `mix.exs`:

```elixir
{:iroh_console, "~> 0.1"}
```

Deliberately **not** restricted to `@all_targets`. The device needs the library,
but your laptop needs the mix tasks — `mix iroh_console.connect` and the
generators — and those come from the same dependency. Only the *server* is
target-only, which is the next step.

## 2. Start the console, on the target only

`mix nerves.new` gives you an `application.ex` that picks children by target.
Add the console to the target branch:

```elixir
defmodule MyApp.Application do
  use Application

  @password_file "/data/iroh_console/password"

  def start(_type, _args) do
    Supervisor.start_link(children(target()), strategy: :one_for_one, name: MyApp.Supervisor)
  end

  # Host: no console. IrohConsole.Identity.File refuses to start without /data,
  # rather than inventing a path and issuing a new identity on every `iex -S mix`.
  defp children(:host), do: []

  defp children(_target) do
    [
      {IrohConsole.Server,
       identity: {IrohConsole.Identity.File, []},
       auth: {IrohConsole.Auth.Password, password_file: @password_file}}
    ]
  end

  defp target, do: Application.get_env(:my_app, :target)
end
```

`IrohConsole.Identity.File` with no options defaults to
`/data/iroh_console/identity`. `/data` is the application data partition: it
survives firmware updates, where the root filesystem is read-only and replaced
wholesale. That matters more than it looks — see step 4.

If the console is misconfigured it logs an error and returns `:ignore` rather
than raising, so a mistake here cannot boot-loop the device. Check the logs for
`iroh_console: not starting:` if it never appears.

## 3. Set a password

Burn the firmware, then get a prompt on the device however you normally do, and
write the password file:

```elixir
iex> File.mkdir_p!("/data/iroh_console")
iex> File.write!("/data/iroh_console/password", IrohConsole.Auth.Password.generate())
iex> File.chmod!("/data/iroh_console/password", 0o600)
iex> File.read!("/data/iroh_console/password")
"MFRGGZDFMZTWQ2LKNNWG23TPOBYXE43U"
```

Copy that value somewhere safe — a password manager. `generate/0` gives 160 bits
of base32, which is what you want here: nothing rate-limits guessing, so length
is the whole defence.

You could put the password in `config/target.exs` instead, with
`auth: {IrohConsole.Auth.Password, password: "…"}`. For a device that never
leaves your desk that is fine. Be aware it is then compiled into the firmware,
so it lives in your repository and in every `.fw` you have ever built.

Restart the app (or reboot) so the server picks up the file.

## 4. Read the ticket, once

Still on the device:

```elixir
iex> {:ok, ticket} = IrohConsole.Server.ticket()
iex> to_string(ticket)
"endpointadjqeoc7a6jlqogqagqn7glafpftpq6s7zxtcwb2zxxcfaq26xyom…"
```

Save that on your laptop. **It stays valid.** The ticket is built from the
device's identity, which lives in `/data`, so it survives reboots and firmware
updates. The direct IP addresses baked into it may go stale when the device
changes network — that is harmless, because the relay is the fallback path and
the relay URL does not change.

The one thing that invalidates a ticket is losing the identity file: a factory
reset, or wiping `/data`. Then you read a new one the same way.

```elixir
# also useful, for the allowlist in step 8
iex> {:ok, addr} = IrohConsole.Server.addr()
iex> addr.id
```

### Showing the endpoint id in the MOTD

If you use [NervesMOTD](https://hex.pm/packages/nerves_motd), `IrohConsole.MOTD`
gives you a ready-made row:

```elixir
# config/target.exs
config :nerves_motd, extra_rows: {IrohConsole.MOTD, :rows, []}
```

```
iroh id : e13b243e722075ed7d40b6e7781efcb52ac4d69536c56b514c311327e47ff899
```

That is the **endpoint id** — the device's public key, and the value
`:peer_allowlist` takes. Having it in the banner saves a trip to
`IrohConsole.Server.addr/1` every time you log in.

It is **not** something you can connect with. An id says *who*, not *where*, and
with address lookup off nothing can turn one into a location — pasting it into
`bin/iroh-console` fails with "that does not look like an endpoint ticket". The
ticket is the connectable value, because it carries the relay URLs and direct
addresses alongside the id.

If the banner is where you would rather keep the connectable value:

```elixir
config :nerves_motd, extra_rows: {IrohConsole.MOTD, :rows, [[show: :ticket]]}
```

That is longer — around 110 to 170 characters depending on how many addresses
the device has — which is why the id is the default.

Options go in the MFA's args, which arrive as the argument to `rows/1`:

```elixir
config :nerves_motd, extra_rows: {IrohConsole.MOTD, :rows, [[truncate: 16, label: "console"]]}
```

`:server` picks a different `IrohConsole.Server` name, `:label` changes the row
label, and `:truncate` shows only a prefix.

The id is shown in full by default. It is 64 characters, and NervesMOTD renders
a single-cell row at full width without clipping, so the line comes to 81
characters — one over a strict 80-column terminal. Showing it whole is still the
better default, because the point is to copy it into an allowlist, and an id you
cannot copy is decoration. `truncate: 16` if you would rather have the tidy line.

During boot the value reads `not running` when no server is started under that
name, or `offline` when it is started but the endpoint has not come online yet.
Both are ordinary, and telling them apart is the difference between "I forgot to
add it to my supervision tree" and "the network is not up".

If you would rather build the row yourself, note that `:extra_rows` is a list of
*rows*, each row a list of `{label, value}` cells — so one line of output is
`[[{"iroh console", …}]]`, a list inside a list. It also has to be a callback
rather than a literal: the endpoint id does not exist when config is evaluated,
since the identity is read and the endpoint started later by your supervision
tree.

The ticket is far too long for a banner — around 170 characters. Read it with
`IrohConsole.Server.ticket()` when you need it, as above.

### Publishing the ticket to NervesHub

If your devices already run [NervesHubLink](https://hex.pm/packages/nerves_hub_link),
you can skip the console trip above entirely. Health reports carry arbitrary
metadata, so the ticket can travel with them and appear on the device's page:

```elixir
# config/target.exs
config :nerves_hub_link,
  health: [
    metadata: %{
      "iroh_ticket" => {IrohConsole.NervesHub, :ticket, []},
      "iroh_endpoint_id" => {IrohConsole.NervesHub, :endpoint_id, []}
    }
  ]
```

This is the one thing that removes the chicken-and-egg from step 4. Without it
you need serial or SSH access once, to read a ticket that only exists on the
device. With it, provision the device, wait for its first health report, and
copy the ticket from NervesHub.

It also stays correct. NervesHubLink resolves each metadata value at report
time — a value may be a literal or an `{module, function, args}` tuple — so the
ticket is regenerated with every report rather than captured once at
provisioning. When the device moves network and its direct addresses change, the
published ticket follows.

Both values are published because they are not interchangeable: the ticket is
what `bin/iroh-console` takes, and the endpoint id is what `:peer_allowlist`
takes. Before the console has started, both read `not running`.

If the console runs under a name other than `IrohConsole.Server`, pass it in the
MFA's args:

```elixir
"iroh_ticket" => {IrohConsole.NervesHub, :ticket, [[server: MyApp.Console]]}
```

The health extension has to be enabled for the device in NervesHub; see
NervesHubLink's own documentation for that.

**What you are publishing.** A ticket says where a device is, not how to get
in — anyone reading it still has to satisfy your auth adapter. It is closer to a
hostname than to a credential. It is also a standing invitation to try, so treat
it as you would an internal hostname, and do not pair it with
`allow_unauthenticated: true`.

## 5. Connect

On your laptop, in the same project:

```bash
mix iroh_console.gen.script      # once — bin/iroh-console is generated, not committed
bin/iroh-console endpointadjqeoc7a6jlq…
```

It asks for the password, then drops you into IEx on the device. `Ctrl-]`
detaches.

Use the wrapper rather than `mix iroh_console.connect` directly. It puts your
terminal into raw mode first, which the BEAM cannot do for itself — without it
input only reaches the device when you press Enter. The session tells you if it
notices.

## 6. Two devices

Nothing special: repeat steps 1–4 on the second device. Each gets its own
identity, its own ticket, and its own password.

Keep the tickets somewhere your shell can reach:

```bash
mkdir -p ~/.config/iroh-console
echo "endpointadjqe…" > ~/.config/iroh-console/kitchen
echo "endpointbfk2r…" > ~/.config/iroh-console/garage
```

```bash
# in ~/.zshrc or ~/.bashrc
console() {
  ( cd ~/code/my_nerves_app && bin/iroh-console "$(cat ~/.config/iroh-console/$1)" )
}
```

Then `console kitchen` or `console garage`.

Give each device a **different** password. A shared one means recovering it from
one device — firmware extraction, a misplaced SD card — hands over both.

## 7. TOTP instead of a password

TOTP replaces a static password with a rotating six-digit code from an
authenticator app. The concrete gain over a password: a code is useless after
about thirty seconds, and cannot be used twice even within its window.

Generate a secret on your laptop, one per device:

```bash
mix iroh_console.gen.secret --issuer "My Nerves" --account kitchen
```

```
secret (base32): HY2TJMEVZ6KSIRJTFT3B4SIG3NKXAJ6S

enrol with:      otpauth://totp/My Nerves:kitchen?secret=HY2TJ…&issuer=My%20Nerves
```

Put that URI into your authenticator app — most will take it from a QR code, and
`qrencode -t ANSI "otpauth://…"` will draw one in your terminal. The app will
show it as **My Nerves: kitchen**, which is why `--account` is worth setting.

Write the secret onto the device:

```elixir
iex> File.write!("/data/iroh_console/totp.secret", "HY2TJMEVZ6KSIRJTFT3B4SIG3NKXAJ6S")
iex> File.chmod!("/data/iroh_console/totp.secret", 0o600)
```

And switch the adapter:

```elixir
{IrohConsole.Server,
 identity: {IrohConsole.Identity.File, []},
 auth: {IrohConsole.Auth.TOTP, secret_path: "/data/iroh_console/totp.secret"}}
```

Connect exactly as before; `bin/iroh-console` asks for a code instead of a
password.

### Several devices, several secrets

Run `gen.secret` once per device with a distinct `--account`, and add each to
your authenticator as its own entry:

```bash
mix iroh_console.gen.secret --issuer "My Nerves" --account kitchen
mix iroh_console.gen.secret --issuer "My Nerves" --account garage
```

You end up scrolling to the right entry when you connect. That is the point: one
compromised device does not let anyone generate codes for the others.

You *can* use one secret across all your devices — write the same base32 to each,
and keep a single authenticator entry. It is more convenient and strictly worse:
the device stores the secret that *verifies* codes, so pulling firmware off any
one of them yields code generation for all of them. For two devices on your own
network that may be a trade you are happy with. Make it knowingly.

### The clock

TOTP needs the device and your phone to agree on the time, within about thirty
seconds either side by default. Nerves devices usually have no battery-backed
clock and depend on NTP after boot, so a device that has just come up on a slow
connection may briefly reject valid codes.

If the clock has never been set at all, the adapter says so specifically rather
than reporting a bad code:

```
iroh_console: device clock is unset, so time-based codes cannot be checked.
```

That is the one to look for before assuming your authenticator has drifted. If
your device's clock is reliably off, widen the window:

```elixir
auth: {IrohConsole.Auth.TOTP, secret_path: "…", drift: 2}
```

Each step is one period, so `drift: 2` accepts roughly ±60 seconds.

## 8. Optional: pin who may connect

Everything so far lets *anyone* who has the ticket attempt the password or code.
If you want the device to refuse unknown callers before they even reach that
point, add your laptop's endpoint id to the allowlist.

Get it by connecting once and reading the device's log — it records the endpoint
id of every session it accepts:

```
iroh_console: session accepted from #IrohBeam.EndpointId<619ee6da…>
```

Then pin it, and give your laptop a stable identity so the id does not change:

```elixir
# device
{IrohConsole.Server,
 identity: {IrohConsole.Identity.File, []},
 auth: {IrohConsole.Auth.Password, password_file: @password_file},
 peer_allowlist: ["619ee6da…"]}
```

```bash
# laptop — otherwise a fresh key, and a fresh id, on every connection
mix iroh_console.connect <ticket> --identity-path ~/.config/iroh-console/identity
```

This is enforced inside `IrohBeam.Endpoint`, below this library, so an unlisted
caller never reaches any of its code. The catch is that it is fixed when the
endpoint starts: changing it means editing config and restarting the device. For
two devices and one laptop that is fine. For anything larger, leave it open and
rely on the auth adapter.

## 9. Optional: your own relay

By default devices use n0's public relays, which is fine — they carry encrypted
traffic they cannot read, and only when a direct connection cannot be made.

If you would rather not depend on someone else's infrastructure, run
[iroh-relay](https://github.com/n0-computer/iroh/tree/main/iroh-relay) and point
both ends at it:

```elixir
# device
{:ok, relay} = IrohBeam.Relay.new("https://relay.example.com")

{IrohConsole.Server,
 identity: {IrohConsole.Identity.File, []},
 auth: {IrohConsole.Auth.Password, password_file: @password_file},
 network: {:custom, [relay]}}
```

```bash
# laptop
bin/iroh-console <ticket> --relay https://relay.example.com
```

Both ends must agree. A device configured against your relay is not reachable by
a client using n0's, and vice versa.

## Troubleshooting

**`could not connect: timeout`** — the device is not reachable. Check it is
powered and online, that both ends are using the same relay, and that the
console actually started (look for `iroh_console: listening as …` in its logs).

**`the device refused the session: authentication failed`** — wrong password or
code. With TOTP, check the device's clock first; see above.

**Everything I type appears twice, or only sends on Enter** — you are running
`mix iroh_console.connect` directly. Use `bin/iroh-console`, generating it with
`mix iroh_console.gen.script` if you have not.

**The console never starts** — look for `iroh_console: not starting:` in the
device log. Usually the identity path (is `/data` writable?) or an allowlist
entry that is not a valid endpoint id.

**The ticket stopped working** — the identity file is gone, most likely a factory
reset or a wiped `/data`. Read the new ticket as in step 4.

## What you have signed up for

An IEx session is unrestricted control of the device, as root. There is no
meaningful way to sandbox it, and no read-only mode. Treat the ticket plus the
credential as equivalent to physical access, and do not run with
`allow_unauthenticated: true` on anything reachable from the internet.
