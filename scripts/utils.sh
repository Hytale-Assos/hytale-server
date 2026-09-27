#!/bin/sh

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

# ==========================================
# COLORS & FORMATTING
# ==========================================

if [ "${NO_COLOR:-FALSE}" = "TRUE" ]; then
    BOLD=''
    DIM=''
    GREEN=''
    RED=''
    YELLOW=''
    CYAN=''
    NC=''
    SYM_OK='OK'
    SYM_FAIL='FAIL'
    SYM_WARN='WARN'
else
    BOLD='\033[1m'
    DIM='\033[2m'
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
    SYM_OK="${GREEN}✔${NC}"
    SYM_FAIL="${RED}✘${NC}"
    SYM_WARN="${YELLOW}⚠${NC}"
fi

# ==========================================
# HELPER FUNCTIONS
# ==========================================

log_break() {
    local lines="${1:-1}"
    while [ "$lines" -gt 0 ]; do
        printf "\n"
        lines=$((lines - 1))
    done
}

log_section() {
    printf "\n${BOLD}${CYAN}SECTION:${NC} ${BOLD}%s${NC}\n" "${1:-}"
}

log_step() {
    printf "  ${NC}%-35s" "${1:-}..."
}

log_success() {
    if [ "${NO_COLOR:-FALSE}" = "TRUE" ]; then
        printf "[ OK ]\n"
    else
        printf "[ ${GREEN}OK${NC} ] %b\n" "${SYM_OK}"
    fi
}

log_warning() {
    if [ "${NO_COLOR:-FALSE}" = "TRUE" ]; then
        printf "[ WARN ]\n"
    else
        printf "[ ${YELLOW}WARN${NC} ] %b\n" "${SYM_WARN}"
    fi
    printf "      ${YELLOW}↳ Note:${NC}  %s\n" "${1:-}"
    if [ -n "${2:-}" ]; then
        printf "      ${DIM}↳ Suggestion: %s${NC}\n" "${2}"
    fi
}

log_error() {
    if [ "${NO_COLOR:-FALSE}" = "TRUE" ]; then
        printf "[ FAIL ]\n"
    else
        printf "[ ${RED}FAIL${NC} ] %b\n" "${SYM_FAIL}"
    fi
    printf "      ${RED}↳ Error:${NC} %s\n" "${1:-}"
    if [ -n "${2:-}" ]; then
        printf "      ${DIM}↳ Hint:   %s${NC}\n" "${2}"
    fi

    if [ "${DEBUG:-FALSE}" != "TRUE" ]; then
        exit 1
    fi
}

# Hand files that are not yet owned by the runtime user over to it.
# Only touches mismatched entries, so it stays fast on large worlds, and is a
# no-op when the container already runs unprivileged (e.g. Podman keep-id).
fix_ownership() {
    local target="${1:-${BASE_DIR:-/home/container}}"
    [ "$(id -u)" = "0" ] || return 0
    find "$target" \( ! -user "${UID:-1000}" -o ! -group "${GID:-1000}" \) \
        -exec chown -h "${UID:-1000}:${GID:-1000}" {} + 2>/dev/null || true
}

# Restrict credential files to the owner. They hold the server's Hytale
# session and the downloader's OAuth tokens.
protect_secrets() {
    local base="${BASE_DIR:-/home/container}"
    for f in \
        "$base/.hytale-downloader-credentials.json" \
        "$base/.hardware-id" \
        "$base/Server/auth.enc" \
        "$base/Server/auth.key"; do
        [ -f "$f" ] && chmod 600 "$f" 2>/dev/null || true
    done
}

# ==========================================
# MAIN EXECUTION FLOW
# ==========================================