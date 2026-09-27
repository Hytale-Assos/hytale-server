#!/bin/sh

# Note: set -eu removed — pipe components and FIFO operations return non-zero
# during normal lifecycle (e.g., FIFO read EOF, broken pipes). Using explicit
# error handling where needed instead.

# Copyright (C) 2026 Daniel Freudenberg
#
# This file is part of github.com/deinfreu/hytale-server-container.
#
# hytale-server-container is free software: you can redistribute it
# and/or modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation, either version 3 of
# the License, or (at your option) any later version.
#
# hytale-server-container is distributed in the hope that it will be
# useful, but WITHOUT ANY WARRANTY; without even the implied warranty
# of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with hytale-server-container. If not, see
# <https://www.gnu.org/licenses/>.

# Load dependencies
. "$SCRIPTS_PATH/utils.sh"

# ==========================================
# HELPER FUNCTIONS
# ==========================================

# Staged updates come from two places: hytale_update.sh (a *.zip dropped into
# the volume) and the in-game /update command. Returns non-zero when nothing
# was staged.
apply_staged_update() {
    [ -f "updater/staging/Server/HytaleServer.jar" ] || return 1

    log_step "Applying staged update"
    mkdir -p Server
    cp -f updater/staging/Server/HytaleServer.jar Server/
    [ -d "updater/staging/Server/Licenses" ]           && rm -rf Server/Licenses && cp -r updater/staging/Server/Licenses Server/
    [ -f "updater/staging/Assets.zip" ]                && cp -f updater/staging/Assets.zip ./
    # Zip updates carry their version; the in-game /update does not report it
    if [ -f "updater/staging/.hytale-version" ]; then
        cp -f updater/staging/.hytale-version ./.hytale-version
    else
        echo "unknown" > ./.hytale-version
    fi
    rm -rf updater/staging
    log_success
}

# The image is tagged with the Hytale release it was built for, but the
# server is downloaded at runtime and updates itself: show both.
report_hytale_version() {
    local installed="unknown"
    [ -s ".hytale-version" ] && installed=$(cat .hytale-version)

    log_step "Hytale server version"
    printf "${GREEN}%s${NC}\n" "$installed"

    [ -n "${HYTALE_TARGET_VERSION:-}" ] || return 0
    if [ "$installed" = "unknown" ]; then
        printf "      ${DIM}↳ Image built for Hytale %s${NC}\n" "$HYTALE_TARGET_VERSION"
    elif [ "$installed" != "$HYTALE_TARGET_VERSION" ]; then
        log_warning "Installed server ($installed) differs from the image's target ($HYTALE_TARGET_VERSION)." \
            "Normal right after a release: the in-game updater or the next image converges them."
    fi
}

build_java_command() {
    cat <<JAVAEOF
stdbuf -oL -eL java $JAVA_ARGS \
    $HYTALE_CACHE_OPT \
    $HYTALE_CACHE_LOG_OPT \
    -Duser.timezone="$TZ" \
    -Dterminal.jline=false \
    -Dterminal.ansi=true \
    -jar "$SERVER_JAR_PATH" \
    $HYTALE_HELP_OPT \
    $HYTALE_ACCEPT_EARLY_PLUGINS_OPT \
    $HYTALE_ALLOW_OP_OPT \
    $HYTALE_AUTH_MODE_OPT \
    $HYTALE_BACKUP_OPT \
    $HYTALE_BACKUP_DIR_OPT \
    $HYTALE_BACKUP_FREQUENCY_OPT \
    $HYTALE_BACKUP_MAX_COUNT_OPT \
    $HYTALE_BARE_OPT \
    $HYTALE_BOOT_COMMAND_OPT \
    $HYTALE_CLIENT_PID_OPT \
    $HYTALE_DISABLE_ASSET_COMPARE_OPT \
    $HYTALE_DISABLE_CPB_BUILD_OPT \
    $HYTALE_DISABLE_FILE_WATCHER_OPT \
    $HYTALE_DISABLE_SENTRY_OPT \
    $HYTALE_EARLY_PLUGINS_OPT \
    $HYTALE_EVENT_DEBUG_OPT \
    $HYTALE_FORCE_NETWORK_FLUSH_OPT \
    $HYTALE_GENERATE_SCHEMA_OPT \
    $HYTALE_IDENTITY_TOKEN_OPT \
    $HYTALE_LOG_OPT \
    $HYTALE_MIGRATE_WORLDS_OPT \
    $HYTALE_MIGRATIONS_OPT \
    $HYTALE_MODS_OPT \
    $HYTALE_OWNER_NAME_OPT \
    $HYTALE_OWNER_UUID_OPT \
    $HYTALE_PREFAB_CACHE_OPT \
    $HYTALE_SESSION_TOKEN_OPT \
    $HYTALE_SHUTDOWN_AFTER_VALIDATE_OPT \
    $HYTALE_SINGLEPLAYER_OPT \
    $HYTALE_TRANSPORT_OPT \
    $HYTALE_UNIVERSE_OPT \
    $HYTALE_VALIDATE_ASSETS_OPT \
    $HYTALE_VALIDATE_PREFABS_OPT \
    $HYTALE_VALIDATE_WORLD_GEN_OPT \
    $HYTALE_VERSION_OPT \
    $HYTALE_WORLD_GEN_OPT \
    --assets "$GAME_DIR/Assets.zip" \
    --bind "$SERVER_IP:$SERVER_PORT"
JAVAEOF
}

# SIGTERM/SIGINT (docker stop, systemctl stop) only reach this shell, never
# java, which sits behind a pipeline. Ask the server to save and shut down
# through its console instead of letting the runtime SIGKILL it later.
request_stop() {
    STOP_REQUESTED=true
    printf "\n"
    log_step "Stop signal received, sending '$HYTALE_STOP_COMMAND'"
    { printf "%s\n" "$HYTALE_STOP_COMMAND" > "$AUTH_PIPE"; } 2>/dev/null || true
    printf "\n"
}

run_server() {
    local java_cmd="$1"
    local exit_file="/tmp/hytale-auth/java.exit"
    # Pre-create it: java may run as the unprivileged user in a root-owned dir
    : > "$exit_file"
    if [ "$(id -u)" = "0" ]; then
        chown "${UID:-1000}:${GID:-1000}" "$exit_file" 2>/dev/null || true
    fi

    # 1. Copy container STDIN (0) to a new file descriptor channel (4)
    # This prevents the background process from being detached to /dev/null
    exec 4<&0

    # 2. Start a background process that listens to channel 4
    # and pushes everything directly into the AUTH_PIPE
    ( while read -r line <&4; do printf "%s\n" "$line" >> "$AUTH_PIPE"; done ) &
    local INPUT_PID=$!

    # 3. Start the Java server with channel 3 connected to the AUTH_PIPE.
    # A pipeline's status is the one of its last command (tee), so java's own
    # exit code is written to a file to keep exit code 8 (update) visible.
    $RUNTIME sh -c "exec 3<>\"$AUTH_PIPE\"; { $java_cmd <&3; echo \$? > \"$exit_file\"; } 2>&1 | stdbuf -oL -eL sed 's/\r\$//' | stdbuf -oL -eL tee \"$AUTH_OUTPUT_LOG\"" &
    local SERVER_PID=$!

    trap request_stop TERM INT
    # `wait` returns early when a trapped signal arrives; keep waiting until
    # the server has actually exited.
    wait "$SERVER_PID"
    while kill -0 "$SERVER_PID" 2>/dev/null; do
        wait "$SERVER_PID"
    done
    trap - TERM INT

    # 4. Clean up the processes and channels gracefully when the server stops
    kill "$INPUT_PID" 2>/dev/null
    exec 4<&-

    JAVA_EXIT_CODE=1
    [ -s "$exit_file" ] && JAVA_EXIT_CODE=$(cat "$exit_file")
}

warn_failed_update() {
    local exit_code="$1"
    local elapsed="$2"

    log_error "Server crashed ${elapsed}s after update" "Exit code: $exit_code"
    printf "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "${YELLOW}Update Failed${NC}\n"
    printf "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"
    printf "Server crashed within ${elapsed}s of applying the update.\n"
    printf "This may indicate the update is incompatible.\n\n"
    printf "${DIM}Check logs in: /home/container/Server/logs/${NC}\n\n"
    printf "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# ==========================================
# MAIN EXECUTION FLOW
# ==========================================

STOP_REQUESTED=false
cd "$GAME_DIR"

while true; do
    APPLIED_UPDATE=false
    apply_staged_update && APPLIED_UPDATE=true
    report_hytale_version

    cd Server
    START_TIME=$(date +%s)

    JAVA_CMD=$(build_java_command)
    run_server "$JAVA_CMD"
    ELAPSED=$(($(date +%s) - START_TIME))

    cd "$GAME_DIR"

    # Exit code 8 = the in-game /update command staged an update and asked
    # for a restart: apply it and relaunch in place.
    if [ "$JAVA_EXIT_CODE" -eq 8 ] && [ "$STOP_REQUESTED" != true ]; then
        log_step "Server requested restart (exit code 8)"
        log_success
        continue
    fi

    if [ "$JAVA_EXIT_CODE" -ne 0 ] && [ "$APPLIED_UPDATE" = true ] && [ "$ELAPSED" -lt 30 ]; then
        warn_failed_update "$JAVA_EXIT_CODE" "$ELAPSED"
    fi

    exit "$JAVA_EXIT_CODE"
done
