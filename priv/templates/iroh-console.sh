#!/bin/sh
#
# Opens a console on a device, with the terminal in raw mode.
#
#   bin/iroh-console TICKET --relay https://relay.example.com
#
# All arguments are passed through to `mix iroh_console.connect`.
#
# It also carries the identity subcommands, so one script covers both having a
# name and using it:
#
#   bin/iroh-console identity new PATH     write an identity, print its endpoint id
#   bin/iroh-console identity show PATH    print an existing identity's endpoint id
#
# This exists because the BEAM cannot put its own terminal into raw mode. Port
# children are forked from erl_child_setup with no controlling terminal, so
# `stty ... </dev/tty` fails from inside the VM regardless of how it was
# launched. The shell starting the VM can do it, and the VM inherits the
# terminal on stdin.

set -e

usage() {
    cat <<'USAGE'
usage:
  iroh-console TICKET [--relay URL] [--code CODE]  open a console on a device
  iroh-console identity new PATH                   write an identity, print its endpoint id
  iroh-console identity show PATH                  print an identity's endpoint id

Anything that is not a subcommand is passed through to `mix iroh_console.connect`.
USAGE
}

# Compilation, with nothing to show for it unless it fails. Both callers below
# want this: the console because `stty raw` clears ONLCR, so anything printed
# afterwards staircases down the screen instead of starting each line at column
# 0; the identity subcommands because their stdout is meant to be piped, and
# "Compiling 3 files" arriving ahead of an endpoint id spoils that.
#
# The output is dropped rather than shown, because warnings and compilation
# errors both go to stderr and there is no way to keep one without the other. A
# failure prints a pointer instead; `mix compile` on its own shows the detail.
compile_quietly() {
    if ! mix compile >/dev/null 2>&1; then
        echo "iroh-console: mix compile failed — run 'mix compile' to see why" >&2
        exit 1
    fi
}

# Handled before any of the machinery below, because none of it applies: these
# print a line and exit, so they want no credential prompt and no raw terminal.
# exec'd, so the exit status is the task's own.
case "${1:-}" in
    identity)
        shift
        case "${1:-}" in
            new)
                shift
                compile_quietly
                exec mix iroh_console.gen.identity "$@"
                ;;
            show)
                shift
                compile_quietly
                exec mix iroh_console.endpoint_id "$@"
                ;;
            *)
                echo "iroh-console: expected 'identity new PATH' or 'identity show PATH'" >&2
                usage >&2
                exit 2
                ;;
        esac
        ;;
    -h | --help | help)
        usage
        exit 0
        ;;
esac

# Compile while the terminal is still cooked. The `mix run` form at the bottom is
# the other half of this: mix replays stored compiler warnings on every compile,
# even one where nothing changed, and they would arrive with the screen raw.
compile_quietly

# Ask for the credential here, before raw mode. Once the terminal is raw there
# is no line editing, nothing is echoed, and Enter sends CR rather than LF — so a
# prompt from inside the BEAM cannot behave properly. Passed by environment
# rather than argv, so it stays out of `ps` output.
#
# What to type depends on the device's auth adapter: a TOTP code, a password, or
# nothing at all if it does not challenge.
has_code=0
for arg in "$@"; do
    if [ "$arg" = "--code" ] || [ "$arg" = "--password" ]; then
        has_code=1
        break
    fi
done

if [ "$has_code" -eq 0 ] && [ -z "${IROH_CONSOLE_CODE:-}" ] && [ -t 0 ]; then
    printf 'code or password (blank if the device asks for neither): '
    read -r code
    if [ -n "$code" ]; then
        IROH_CONSOLE_CODE="$code"
        export IROH_CONSOLE_CODE
    fi
fi

if [ -t 0 ]; then
    saved=$(stty -g)
    # Restore on any exit, including a crash or Ctrl-C, or the shell is left
    # raw and effectively unusable.
    restore() {
        stty "$saved" 2>/dev/null || stty sane
        printf '\n'
    }
    trap restore EXIT INT TERM HUP

    # raw    every keystroke reaches the device as typed, so Ctrl-C interrupts
    #        the remote shell rather than killing this one
    # -echo  the device echoes; without this every character appears twice
    stty raw -echo
else
    echo "iroh-console: stdin is not a terminal; input will be line-buffered" >&2
fi

# Run through `mix run` rather than calling `mix iroh_console.connect` directly.
#
# To find a task that lives in a dependency, mix first loads the dependency code
# paths, and that step replays every stored compiler warning from every dep —
# arriving after the terminal is already raw, which is what staircases. Nothing
# passed to the task can prevent it: the replay happens while mix is still
# working out which task to run.
#
# `run` is built into mix, so it is found without that step, and
# `--no-deps-check` then loads the deps without compiling or replaying them.
# Everything has already been compiled above, while the terminal was cooked.
#
# `--no-start` matters just as much: `mix run` starts the current project's
# application by default, which for a device project means booting the endpoint,
# its supervision tree and its watchers, all logging over the raw terminal. The
# task only needs `:iroh_console`, which it starts for itself.
#
# Arguments after `--` arrive as `System.argv()`.
mix run --no-compile --no-deps-check --no-start \
    -e 'Mix.Task.run("iroh_console.connect", System.argv())' -- "$@"
