#!/bin/sh
set -eu

# `hytale-downloader` command of the image.
#
# Hypixel's downloader is NOT shipped in the image: the Hytale EULA (§3.3)
# forbids redistributing any file pertaining to the game. It is fetched from
# Hypixel on first use into the data volume, then reused (it checks for its
# own updates when it runs).

DL_URL="https://downloader.hytale.com/hytale-downloader.zip"
DL_DIR="${HYTALE_DOWNLOADER_DIR:-${BASE_DIR:-/home/container}/.hytale-downloader}"
DL_BIN="$DL_DIR/hytale-downloader-linux-amd64"

install_downloader() {
    mkdir -p "$DL_DIR"
    tmp=$(mktemp -d "$DL_DIR/.install.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT

    echo "[hytale-downloader] Not installed yet, fetching $DL_URL" >&2
    curl -fsSL --retry 3 --retry-delay 5 -o "$tmp/downloader.zip" "$DL_URL"
    7z x -y -o"$tmp/x" "$tmp/downloader.zip" >/dev/null

    bin=$(find "$tmp/x" -type f -name 'hytale-downloader-linux-amd64' | head -n 1)
    if [ -z "$bin" ]; then
        echo "[hytale-downloader] hytale-downloader-linux-amd64 not found in the archive" >&2
        exit 1
    fi

    chmod 755 "$bin"
    mv -f "$bin" "$DL_BIN"
    echo "[hytale-downloader] Installed to $DL_BIN (sha256 $(sha256sum "$DL_BIN" | cut -d' ' -f1))" >&2

    rm -rf "$tmp"
    trap - EXIT
}

[ -x "$DL_BIN" ] || install_downloader

# Hypixel only publishes an x86_64 build: run it through QEMU elsewhere
case "$(uname -m)" in
    x86_64|amd64)
        exec "$DL_BIN" "$@"
        ;;
    *)
        QEMU_BIN=$(command -v qemu-x86_64-static || command -v qemu-x86_64 || true)
        if [ -z "$QEMU_BIN" ]; then
            echo "[hytale-downloader] $(uname -m) host needs qemu-x86_64 to run the downloader" >&2
            exit 1
        fi
        exec "$QEMU_BIN" "$DL_BIN" "$@"
        ;;
esac
