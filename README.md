# IrohConsole

A remote IEx console for Nerves devices, over a peer-to-peer [iroh](https://iroh.computer)
connection.

A device behind NAT, on cellular, or on a network you do not control is dialled
by its **public key** rather than its address. iroh handles hole punching and
falls back to a relay when no direct path can be established, so there is no
port to forward, no VPN, and no inbound firewall rule.

```
operator                                              device
────────                                              ──────
mix iroh_console.connect  ──►  iroh  ──►  relay  ──►  IrohConsole.Server
                                 │                          │
                            hole punch                    ExTTY
                          (direct if it works)          (real IEx)
```

## Guides

**[Your own Nerves devices](guides/nerves.md)** — end-to-end walkthrough for one
or two personal devices, covering password auth, TOTP across several devices,
and pinning an allowlist.

## Status

A proof of concept, verified end to end: a real IEx shell, over a real relay,
with a TOTP handshake. Not yet used in production, and the API should be
expected to move.

## Install

```elixir
def deps do
  [{:iroh_console, "~> 0.1"}]
end
```

Requires Elixir 1.20+. That floor comes from `iroh_beam`, not from this
library, so it can widen if that requirement is ever relaxed.

## Try it

Two terminals, no device needed.

```bash
mix deps.get
mix iroh_console.gen.script            # creates bin/iroh-console; it is gitignored
mix compile                            # take the build lock once, up front
mix run --no-halt examples/listen.exs
```

It prints an endpoint id, a ticket, and the command to connect with. In another
terminal, paste that command:

```bash
bin/iroh-console <ticket>
```

The same generator step applies in your own project — the wrapper is never
committed, in this repo or yours.

By default this uses n0's public relays and **no authentication** — anyone
holding the ticket gets a root shell. Fine on your own machine, wrong everywhere
else. Set `IROH_CONSOLE_TOTP=1` to require a code.

Press `Ctrl-]` to detach.

## On a device

```elixir
children = [
  {IrohConsole.Server,
   identity: {IrohConsole.Identity.File, []},
   auth: {IrohConsole.Auth.TOTP, secret_path: "/data/iroh_console/totp.secret"}}
]
```

The device needs to publish its address somewhere an operator can reach it —
with address lookup disabled there is no ambient way to find it:

```elixir
{:ok, ticket} = IrohConsole.Server.ticket()
```

Print it at boot, or send it to your control plane.

### Generating a TOTP secret

```bash
mix iroh_console.gen.secret --account device-1234 --out /tmp/totp.secret
```

Prints the base32 secret and an `otpauth://` URI to scan. **Give each device its
own** — the device stores a secret that *verifies* codes, so extracting firmware
from one device yields code generation for every device sharing it.

## NervesMOTD

`IrohConsole.MOTD` provides a ready-made row showing the device's endpoint id:

```elixir
config :nerves_motd, extra_rows: {IrohConsole.MOTD, :rows, []}
```

The endpoint id is what `:peer_allowlist` takes. It is *not* connectable — an id
says who, not where — so use `[[show: :ticket]]` if you want the value that
`bin/iroh-console` accepts.

## Configuration

### `IrohConsole.Server`

| Option | Default | |
|---|---|---|
| `:identity` | `IrohConsole.Identity.File` | where the iroh key lives |
| `:auth` | none | `IrohConsole.Auth` adapter, `{module, opts}` |
| `:network` | `:n0` | `:n0`, or `{:custom, relays}` |
| `:peer_allowlist` | `:all` | endpoint ids that may connect |
| `:alpn` | `"iroh-console/1"` | |
| `:max_sessions` | `4` | concurrent sessions, authenticated or not |
| `:idle_timeout` | 30 min | |
| `:handshake_timeout` | 10 s | covers stream setup and auth together |
| `:direct_ip` | `true` | `false` removes IP transports entirely |
| `:allow_unauthenticated` | `false` | required to run with no adapter |

Misconfiguration logs an error and returns `:ignore` rather than raising. On a
field device a boot loop is far worse than a missing console.

### Relays

`:n0` uses the public relays. To run your own, see
[iroh-relay](https://github.com/n0-computer/iroh/tree/main/iroh-relay):

```elixir
{:ok, relay} = IrohBeam.Relay.new("https://relay.example.com", token: "…")
network: {:custom, [relay]}
```

Relays do **not** mesh. A relay only delivers to endpoints in its own registry,
so both ends must agree on one, and a single relay hostname must not be scaled
across multiple instances.

## Security model

**A session is unrestricted control of the device**, as root on most Nerves
systems. There is no meaningful way to sandbox IEx. Treat access as equivalent
to physical access.

Access is decided at two layers:

**`:peer_allowlist`** names which public keys may connect at all. It is enforced
inside `IrohBeam.Endpoint`, below this library, so no bug here can wave a peer
through — and an unlisted peer never reaches any Elixir code. It is fixed at
endpoint start, so revoking someone means a restart, which makes it a poor fit
for a fleet whose operators change.

**`IrohConsole.Auth`** runs per session, after iroh has cryptographically proven
the peer's identity. This is the mechanism intended for general use: operators
prove they hold a credential, and devices never need to know them in advance.

Because the allowlist defaults to `:all`, an unset `:auth` would mean an
unauthenticated root shell for anyone who learns the address. That combination
**refuses to start**. `allow_unauthenticated: true` is the explicit opt-in.

Everything else is layered on top: connections are end-to-end encrypted by iroh,
gated by ALPN, and the device sends a bare `"authentication failed"` to a
rejected peer while logging the real reason locally, so a caller cannot probe
for which part it got wrong.

### Writing an auth adapter

Challenge/response, so a clock is not part of the contract:

```elixir
@behaviour IrohConsole.Auth

def challenge(_context), do: {:ok, IrohConsole.Auth.nonce()}

def verify(context, nonce, response) do
  # context.endpoint_id is proven by iroh's handshake
  # context.opts is whatever you passed as {Module, opts}
  if IrohConsole.Auth.secure_compare(response, expected(nonce)), do: :ok, else: {:error, :bad}
end
```

Use `secure_compare/2` rather than `==/2` on anything secret — the latter returns
early on the first differing byte and leaks the length of a correct prefix.

An adapter needing state exports `child_spec/1`; `IrohConsole.Server` starts it
first, so it can never be configured but not running.

### Adapters that ship

| | |
|---|---|
| `IrohConsole.Auth.Password` | a shared password. Simplest real check. |
| `IrohConsole.Auth.TOTP` | rotating codes, RFC 6238. |
| `IrohConsole.Auth.None` | no check. Requires `allow_unauthenticated: true`. |

```elixir
auth: {IrohConsole.Auth.Password, password_file: "/data/iroh_console/password"}
```

Prefer `:password_file` over `:password` on a device: a password in
`config/*.exs` is compiled into the release, so it lives in your repository and
in every build artefact you have ever shipped. `IrohConsole.Auth.Password.generate/0`
produces a 160-bit one, and the adapter warns if the configured password is
under 12 characters.

Nothing in that adapter rate-limits guessing. One connection buys one attempt,
so the practical ceiling is connection setup plus `:max_sessions` — enough to
make online guessing slow, nowhere near enough to make a short password safe.

Passwords do not rotate, which is the concrete way they are weaker than TOTP: a
captured code is useless after one period, while a captured password works until
someone changes it on the device.

### TOTP, and its limits

`IrohConsole.Auth.TOTP` implements RFC 6238 via `nimble_totp`, including the
reuse prevention the RFC requires — the last accepted period is tracked, and
verification **refuses** if the tracker is not running rather than silently
accepting replayable codes.

Two honest caveats:

**It needs a clock.** Many Nerves targets have no battery-backed RTC and depend
on NTP, and a console is most wanted when a device is unhealthy. `:drift`
defaults to ±1 period (~±30s); a clock earlier than 2024 is reported as
`:clock_unset` with its own log line, so it is diagnosable rather than a
mystifying "authentication failed".

**The device holds a secret.** Anyone who extracts firmware can generate codes
for that device. An adapter where the device holds only a *public* key —
verifying an operator's signature over the device's nonce — avoids this
entirely, and is the intended direction for fleet use. The seam supports it; it
is simply not written yet.

## Identity

The device's key is its name: the public half is the endpoint id that appears in
allowlists and in whatever your control plane stores. Persistence is therefore a
correctness requirement, not a convenience — an identity that changes on reboot
invalidates every reference to it.

`IrohConsole.Identity.File` defaults to `/data` on Nerves, which survives
firmware updates (the root filesystem is read-only and replaced wholesale). Off
device there is no `/data`, and rather than invent a path it refuses and asks
for `:path` — a temp-dir fallback would look like it worked while issuing a new
identity on every boot.

The key is stored **unencrypted**: iroh needs it at startup with no operator
present. NervesKey cannot hold it — that is an ATECC608 doing ECDSA P-256, while
iroh identities are ed25519 — so the security of that file is the security of
the data partition.

## Terminal handling

`mix iroh_console.connect` works on its own, but the terminal stays in cooked
mode: input reaches the device only when you press Enter, rather than as you
type. The session tells you when it detects this.

For a proper interactive session, generate the wrapper into your project once:

```bash
mix iroh_console.gen.script      # writes bin/iroh-console, executable
bin/iroh-console <ticket>
```

It puts the terminal in raw mode before the VM starts and restores it on any
exit path, including Ctrl-C and crashes.

The BEAM cannot do this itself: port children are forked from `erl_child_setup`
with no controlling terminal, so `stty ... </dev/tty` fails from inside the VM
regardless of how it was launched.

The wrapper also prompts for the TOTP code *before* enabling raw mode — once the
terminal is raw there is no echo and Enter sends CR rather than LF, so a prompt
from inside the VM cannot behave properly. The code is passed via
`IROH_CONSOLE_CODE` so it stays out of `ps` and shell history.

Resize is polled once a second via `:io.columns/1`, because Erlang does not
expose `SIGWINCH`.

If input misbehaves, `examples/tty_probe.exs` shows exactly what the terminal
delivers — per keystroke or per line, and whether Enter arrives as CR or LF.

## Examples

| | |
|---|---|
| `examples/listen.exs` | run the device half, print a ticket |
| `examples/end_to_end.exs` | both halves in one VM, asserts a shell works |
| `examples/tty_probe.exs` | diagnose terminal input |

## Mix tasks

| | |
|---|---|
| `mix iroh_console.connect TICKET` | open a console |
| `mix iroh_console.gen.script` | write `bin/iroh-console` into this project |
| `mix iroh_console.gen.secret --account NAME` | generate a per-device TOTP secret |

`connect` takes, and the wrapper passes through:

| | |
|---|---|
| `--relay URL` | a custom relay. Repeatable. Without it, n0's relays are used — which will not reach a device configured against your own. |
| `--relay-token TOKEN` | for a relay that requires one |
| `--relay-only` | drop IP transports, so traffic must go via the relay. Useful when a direct path is being attempted and failing. |
| `--code CODE` | skip the prompt — a TOTP code or a password, depending on the device. `--password` is an alias. Visible in shell history; `IROH_CONSOLE_CODE` is read too and is not. |
| `--alpn ALPN` | defaults to `iroh-console/1` |
| `--timeout MS` | connect timeout, defaults to 30000 |
| `--identity-path PATH` | keep this client's key in a file so its endpoint id is stable. Needed if the device pins a `:peer_allowlist`. |

`end_to_end.exs` runs both ends with `direct_ip: false`, so traffic has nowhere
to go but the relay — without that, two endpoints on one host connect over
loopback and the relay is never exercised.

## Development

```bash
mix test                              # no network required
mix format --check-formatted
mix compile --warnings-as-errors
```

The test suite runs entirely against fakes. `IrohConsole.TransportPipe` wires a
`Session` and a `Client` back to back so the two halves of the protocol are
tested against each other — that loopback is what caught the shell process
surviving a session ending normally.

Anything touching a real relay lives in `examples/`, deliberately outside the
suite: CI should not depend on someone else's infrastructure, and it should not
hammer yours.

## Known limitations

- **NAT traversal is unproven.** Everything verified so far ran both ends on one
  host. Two machines on different networks is the outstanding test.
- **QUIC address discovery** requires a relay that has it enabled; without it,
  hole punching degrades and traffic stays relayed.
- **Revoking an allowlisted operator** needs an endpoint restart, which drops
  every live session. Do dynamic revocation in an auth adapter instead.
- **One session, one shell.** There is no reattach — disconnecting ends it.

## License

Apache-2.0
