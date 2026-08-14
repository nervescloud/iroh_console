#!/bin/sh
#
# Opens a console on a device, with the terminal in raw mode.
#
#   bin/iroh-console TICKET --relay https://relay.example.com
#
# All arguments are passed through to `mix iroh_console.connect`.
#
# This exists because the BEAM cannot put its own terminal into raw mode. Port
# children are forked from erl_child_setup with no controlling terminal, so
# `stty ... </dev/tty` fails from inside the VM regardless of how it was
# launched. The shell starting the VM can do it, and the VM inherits the
# terminal on stdin.

set -e

# Ask for the code here, before raw mode. Once the terminal is raw there is no
# line editing, nothing is echoed, and Enter sends CR rather than LF — so a
# prompt from inside the BEAM cannot behave properly. Passed by environment
# rather than argv, so it stays out of `ps` output.
has_code=0
for arg in "$@"; do
    if [ "$arg" = "--code" ]; then
        has_code=1
        break
    fi
done

if [ "$has_code" -eq 0 ] && [ -z "${IROH_CONSOLE_CODE:-}" ] && [ -t 0 ]; then
    printf 'code (leave blank if the device does not ask for one): '
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

mix iroh_console.connect "$@"
