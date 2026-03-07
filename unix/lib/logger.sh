#!/usr/bin/env bash
# lib/logger.sh
# Colored console output and file logging

LOG_FILE=""

init_logger() {
    local log_dir="$1"
    mkdir -p "$log_dir"
    LOG_FILE="$log_dir/session.log"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "=== SlipStream Connector Session - $timestamp ===" > "$LOG_FILE"
}

log() {
    local level="${1:-Info}"
    local message="$2"
    local timestamp
    timestamp=$(date "+%H:%M:%S")

    local prefix color reset
    reset="\033[0m"
    case "$level" in
        Info)    prefix="[*]"; color="\033[36m" ;;   # Cyan
        Success) prefix="[+]"; color="\033[32m" ;;   # Green
        Warning) prefix="[!]"; color="\033[33m" ;;   # Yellow
        Error)   prefix="[-]"; color="\033[31m" ;;   # Red
        Debug)   prefix="[.]"; color="\033[90m" ;;   # Dark gray
        *)       prefix="[*]"; color="\033[36m" ;;
    esac

    echo -e "${color}${timestamp} ${prefix} ${message}${reset}"

    if [[ -n "$LOG_FILE" ]]; then
        echo "$timestamp $prefix $message" >> "$LOG_FILE"
    fi
}

print_banner() {
    echo -e "\033[36m"
    cat << 'BANNER'
  ____  _ _       ____  _
 / ___|| (_)_ __ / ___|| |_ _ __ ___  __ _ _ __ ___
 \___ \| | | '_ \\___ \| __| '__/ _ \/ _` | '_ ` _ \
  ___) | | | |_) |___) | |_| | |  __/ (_| | | | | | |
 |____/|_|_| .__/|____/ \__|_|  \___|\__,_|_| |_| |_|
            |_|        Auto Connector v1.0
BANNER
    echo -e "\033[0m"
}
