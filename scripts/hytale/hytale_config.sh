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

# Constants
# The server runs with CWD=$BASE_DIR/Server (see hytale_start.sh: `cd Server`),
# so it reads/writes Server/config.json — NOT $BASE_DIR/config.json. Manage the
# file the server actually loads, otherwise env overrides silently never apply.
readonly CONFIG_FILE="${BASE_DIR:-/home/container}/Server/config.json"
readonly CONFIG_BACKUP_SUFFIX=".invalid.bak"
readonly CONFIG_TMP_SUFFIX=".tmp"

# ==========================================
# HELPER FUNCTIONS
# ==========================================

create_default_config() {
    cat <<'EOF' > "$CONFIG_FILE"
{
    "Version": 3,
    "ServerName": "Hytale Server",
    "MOTD": "",
    "Password": "",
    "MaxPlayers": 100,
    "MaxViewRadius": 32,
    "LocalCompressionEnabled": false,
    "Defaults": { 
        "World": "default", 
        "GameMode": "Adventure" 
    },
    "ConnectionTimeouts": { 
        "JoinTimeouts": {} 
    },
    "RateLimit": {},
    "Modules": {},
    "LogLevels": {},
    "Mods": {},
    "DisplayTmpTagsInStrings": false,
    "PlayerStorage": { 
        "Type": "Hytale" 
    }
}
EOF
}

validate_config_json() {
    jq empty "$CONFIG_FILE" >/dev/null 2>&1
}

apply_env() {
    local path="$1"
    local value="$2"
    local value_type="${3:-auto}"
    local tmp_file="${CONFIG_FILE}${CONFIG_TMP_SUFFIX}"
    local filter

    [ -z "$value" ] && return 0

    # The value is always passed via --arg, never spliced into the filter, so
    # quotes or jq syntax in it (e.g. a password) cannot break the config.
    case "$value_type" in
        string) filter="$path = \$v" ;;
        number) filter="$path = (\$v | tonumber)" ;;
        boolean)
            case "$value" in
                true|TRUE|1|yes|YES) filter="$path = true" ;;
                false|FALSE|0|no|NO) filter="$path = false" ;;
                *) printf "      ${YELLOW}⚠ Invalid boolean value for %s: %s${NC}\n" "$path" "$value"; return 1 ;;
            esac
            ;;
        auto)
            case "$value" in
                true|false) filter="$path = (\$v == \"true\")" ;;
                *)          filter="$path = \$v" ;;
            esac
            ;;
    esac

    if ! jq --arg v "$value" "$filter" "$CONFIG_FILE" > "$tmp_file" 2>/dev/null; then
        printf "      ${YELLOW}⚠ Failed to apply %s${NC}\n" "$path"
        rm -f "$tmp_file"
        return 1
    fi

    mv -f "$tmp_file" "$CONFIG_FILE"
}

display_config_value() {
    local label="$1"
    local jq_path="$2"
    local default_val="$3"
    local color="${4-GREEN}"
    local color_code=""

    # $4 names one of the utils.sh color variables (GREEN, CYAN, ...)
    [ -n "$color" ] && eval "color_code=\${$color:-}"

    log_step "$label"
    local value=$(jq -r "$jq_path" "$CONFIG_FILE" 2>/dev/null || echo "$default_val")
    if [ -n "$value" ] && [ "$value" != "null" ]; then
        case "$label" in
            *"Password"*) printf "${GREEN}enabled${NC} ${DIM}(hidden)${NC}\n" ;;
            *)            printf "${color_code}%s${NC}\n" "$value" ;;
        esac
    else
        case "$label" in *"Password"*) printf "${DIM}disabled${NC}\n" ;; *) printf "${DIM}not set${NC}\n" ;; esac
    fi
}

# ==========================================
# MAIN EXECUTION FLOW
# ==========================================

log_section "Server Configuration Management"

# Step 1: Ensure configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    log_step "Generating new config"; create_default_config; log_success
else
    log_step "Updating existing config"
    if ! validate_config_json; then
        printf "      ${YELLOW}⚠ Invalid JSON detected. Backing up and recreating...${NC}\n"
        mv -f "$CONFIG_FILE" "${CONFIG_FILE}${CONFIG_BACKUP_SUFFIX}"
        create_default_config
    fi
    log_success
fi

# Step 2: Apply environment variable overrides
log_step "Applying environment overrides"
apply_env ".ServerName"               "${HYTALE_SERVER_NAME:-}"       "string" || true
apply_env ".MOTD"                     "${HYTALE_MOTD:-}"              "string" || true
apply_env ".Password"                 "${HYTALE_PASSWORD:-}"          "string" || true
apply_env ".MaxPlayers"               "${HYTALE_MAX_PLAYERS:-}"       "number" || true
apply_env ".MaxViewRadius"            "${HYTALE_MAX_VIEW_RADIUS:-}"   "number" || true
apply_env ".LocalCompressionEnabled"  "${HYTALE_COMPRESSION:-}"       "boolean" || true
apply_env ".Defaults.World"           "${HYTALE_WORLD:-}"             "string" || true
apply_env ".Defaults.GameMode"        "${HYTALE_GAMEMODE:-}"          "string" || true
log_success

# Step 3: Display configuration summary
printf "\n"
display_config_value "Config Version"            ".Version"                            "3"       ""
display_config_value "Server Name"              ".ServerName"                         "Hytale Server"
display_config_value "MOTD"                     ".MOTD"                               ""
display_config_value "Password Protection"      ".Password"                           ""
display_config_value "Max Players"              ".MaxPlayers"                         "100"
display_config_value "Max View Radius"          ".MaxViewRadius"                      "12"

log_step "Local Compression"
COMPRESSION=$(jq -r '.LocalCompressionEnabled' "$CONFIG_FILE" 2>/dev/null || echo "false")
[ "$COMPRESSION" = "true" ] && printf "${GREEN}enabled${NC}\n" || printf "${DIM}disabled${NC}\n"

display_config_value "Default World"     ".Defaults.World"     "default"
display_config_value "Default Game Mode" ".Defaults.GameMode"  "Adventure"