# IrohConsole

A remote IEx console for Elixir applications, over a peer-to-peer [iroh](https://iroh.computer)
connection.

A device behind NAT, on cellular, or on a network you do not control is dialled
by its **public key** rather than its address. iroh handles hole punching and
falls back to a relay when no direct path can be established, so there is no
port to forward, no VPN, and no inbound firewall rule.

```
operator                                           device
────────                                           ──────
bin/iroh-console  ──►  iroh  ──►  relay  ──►  IrohConsole.Server
                        │                            │
                    hole punch                     ExTTY
                (direct if it works)             (real IEx)
```

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

The same generator step applies in your own project.

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

And then print its 'ticket' (used for establishing a connection):

```elixir
{:ok, ticket} = IrohConsole.Server.ticket()
```

### Generating a TOTP secret

```bash
mix iroh_console.gen.secret --account device-1234 --out /tmp/totp.secret
```

Prints the base32 secret and an `otpauth://` URI to scan. **Give each device its
own** — the device stores a secret that *verifies* codes, so extracting firmware
from one device yields code generation for every device sharing it.

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

## Security model

**A session is unrestricted control of the device**, as root on most Nerves
systems. There is no meaningful way to sandbox IEx. Treat access as equivalent
to physical access.

Access is decided at two layers:

**`:peer_allowlist`** names which public keys may connect. It is enforced
inside `IrohBeam.Endpoint`, below this library, so an unlisted peer never reaches 
any Elixir code. It is fixed at endpoint start, so revoking someone means a restart, 
which makes it a poor fit for a fleet whose operators change.

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

### TOTP, and its limits

`IrohConsole.Auth.TOTP` implements RFC 6238 via `nimble_totp`, including the
reuse prevention the RFC requires — the last accepted period is tracked, and
verification **refuses** if the tracker is not running rather than silently
accepting replayable codes.

Please be aware:

**It needs a clock.** Many Nerves targets have no battery-backed RTC and depend
on NTP. `:drift` defaults to ±1 period (~±30s); a clock earlier than 2024 is 
reported as `:clock_unset` with its own log line, so it is diagnosable rather 
than a mystifying "authentication failed".

**The device holds a secret.** Anyone who extracts firmware can generate codes
for that device. An adapter where the device holds only a *public* key —
verifying an operator's signature over the device's nonce — avoids this
entirely, and is the intended direction for fleet use. The seam supports it; it
is simply not written yet.

## Identity

The device's key is its name: the public half is the endpoint id that appears in
allowlists and in whatever your control plane stores. Persistence is therefore a
correctness requirement, and an identity that changes on reboot invalidates every 
reference to it.

`IrohConsole.Identity.File` defaults to `/data` on Nerves, which survives
firmware updates (the root filesystem is read-only and replaced wholesale). Off
device there is no `/data`, and rather than invent a path it refuses and asks
for `:path` — a temp-dir fallback would look like it worked while issuing a new
identity on every boot.

The key is stored **unencrypted**: iroh needs it at startup with no operator
present. NervesKey cannot hold it (an ATECC608 doing ECDSA P-256), while
iroh identities are ed25519, so the security of that file is the security of
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
| `--code CODE` | skip the prompt. Visible in shell history; `IROH_CONSOLE_CODE` is read too and is not. |
| `--alpn ALPN` | defaults to `iroh-console/1` |
| `--timeout MS` | connect timeout, defaults to 30000 |

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

## License

Apache-2.0
