#!/bin/sh
set -eu

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

extract_and_stage_server() {
    local ZIP_FILE="$1"
    local STAGING_DIR="$GAME_DIR/updater/staging"

    log_step "Extracting to staging area"
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"

    if [ "${DEBUG:-FALSE}" = "TRUE" ]; then
        printf "      ${DIM}↳ Source:${NC} %s\n" "$(basename "$ZIP_FILE")"
        printf "      ${DIM}↳ Target:${NC} ${GREEN}%s${NC}\n" "$STAGING_DIR"
    fi

    if 7z x "$ZIP_FILE" -aoa -bsp1 -mmt=on -o"$STAGING_DIR" >/dev/null 2>&1; then
        log_success
    else
        log_error "Extraction failed" "Check disk space or 7z compatibility."
        exit 1
    fi

    # Only validate here. The staged files are applied by hytale_start.sh
    # (apply_staged_update), the same path used by the in-game /update command.
    log_step "Validating update package"
    if [ -f "$STAGING_DIR/Server/HytaleServer.jar" ]; then
        # The package is named after the server version (e.g. 0.6.8.zip)
        basename "$ZIP_FILE" .zip > "$STAGING_DIR/.hytale-version"
        log_success
    else
        rm -rf "$STAGING_DIR"
        log_error "Invalid update package" "Missing Server/HytaleServer.jar"
        exit 1
    fi

    log_step "Cleaning up"
    rm -f "$ZIP_FILE"
    fix_ownership "$GAME_DIR/updater"
    log_success
}

# ==========================================
# MAIN EXECUTION FLOW
# ==========================================

log_section "Hytale Server Update"
log_warning "Update package detected." "Applying server update..."

# Locate the downloaded ZIP file
ZIP_FILE=""
for f in "$BASE_DIR"/*.zip; do
    # Get just the filename
    filename=$(basename "$f")

    # Extract base name to validate against the pattern
    base="${filename%.zip}"

    # Regex breakdown:
    # ^[0-9]+\.[0-9]+\.[0-9]+  -> Matches the main version (e.g., 0.6.0)
    # (-[a-zA-Z0-9.-]+)?       -> Optionally matches a hyphen followed by pre-release info (e.g., -pre.7)
    # $                        -> End of string
    if echo "$base" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$'; then
        ZIP_FILE="$f"
        break
    fi
done

if [ -z "$ZIP_FILE" ]; then
    log_error "No update package found." "Expected *.zip in $BASE_DIR"
    exit 1
fi

[ "${DEBUG:-FALSE}" = "TRUE" ] && printf "      ${DIM}↳ Package:${NC} %s\n" "$(basename "$ZIP_FILE")"

extract_and_stage_server "$ZIP_FILE"