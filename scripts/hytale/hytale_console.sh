#!/bin/sh
set -eu

# Send a command to the running server console, for setups without an
# attached TTY (systemd / Podman Quadlets, detached containers).
#
#   podman exec hytale hytale-cmd /op add Steve
#   docker exec hytale-server hytale-cmd /stop

CONSOLE_PIPE="/tmp/hytale-auth/console.in"

if [ "$#" -eq 0 ]; then
    echo "Usage: hytale-cmd <command...>   e.g. hytale-cmd /op add Steve" >&2
    exit 64
fi

if [ ! -p "$CONSOLE_PIPE" ]; then
    echo "Server console not available ($CONSOLE_PIPE missing). Is the server running?" >&2
    exit 1
fi

printf '%s\n' "$*" > "$CONSOLE_PIPE"
echo "Sent: $*"
