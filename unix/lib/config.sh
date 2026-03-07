#!/usr/bin/env bash
# lib/config.sh
# Parses config.ini and loads/prepares the DNS list

# Default config values
declare -A CONFIG
CONFIG[Domain]="example.com"
CONFIG[CongestionControl]="bbr"
CONFIG[KeepAliveInterval]="2000"
CONFIG[Timeout]="3"
CONFIG[Workers]="5"
CONFIG[ConnectivityUrl]="http://connectivitycheck.gstatic.com/generate_204"
CONFIG[FallbackUrl]="http://www.msftconnecttest.com/connecttest.txt"
CONFIG[ConnectivityTimeout]="5"
CONFIG[HealthCheckInterval]="30"
CONFIG[MaxReconnectAttempts]="0"
CONFIG[ShuffleDns]="true"
CONFIG[PrioritizeKnownGood]="true"
CONFIG[SkipPreviouslyFailed]="true"

# Helper: check if a config value is truthy (true, yes, 1)
_is_true() {
    case "${1,,}" in
        true|yes|1) return 0 ;;
        *) return 1 ;;
    esac
}

read_config() {
    local config_path="$1"

    if [[ ! -f "$config_path" ]]; then
        log Warning "Config file not found at $config_path, using defaults"
        return
    fi

    while IFS= read -r line; do
        # Trim whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip comments, section headers, empty lines
        [[ -z "$line" || "$line" == \#* || "$line" == \;* || "$line" == \[* ]] && continue

        # Parse key = value
        if [[ "$line" =~ ^([A-Za-z_]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            # Strip inline comments
            value="${value%%#*}"
            value="${value%"${value##*[![:space:]]}"}"

            # Only set if key exists in defaults
            if [[ -v "CONFIG[$key]" ]]; then
                CONFIG[$key]="$value"
            fi
        fi
    done < "$config_path"
}

read_dns_list() {
    local dns_path="$1"
    local results_dir="$2"

    if [[ ! -f "$dns_path" ]]; then
        log Error "DNS list not found at $dns_path"
        DNS_LIST=()
        return
    fi

    # Load all DNS entries (lines starting with a digit, trimmed)
    mapfile -t all_dns < <(grep -E '^\s*[0-9]' "$dns_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')
    log Info "Loaded ${#all_dns[@]} DNS entries from list"

    local -A known_bad
    local -a known_good_list=()

    # Load previously known-good DNS
    local working_path="$results_dir/working-dns.txt"
    if _is_true "${CONFIG[PrioritizeKnownGood]}" && [[ -f "$working_path" ]]; then
        while IFS='|' read -r dns _rest; do
            dns="${dns#"${dns%%[![:space:]]*}"}"
            dns="${dns%"${dns##*[![:space:]]}"}"
            [[ -n "$dns" ]] && known_good_list+=("$dns")
        done < "$working_path"
        log Info "Loaded ${#known_good_list[@]} previously working DNS entries"
    fi

    # Load previously failed DNS
    local failed_path="$results_dir/failed-dns.txt"
    if _is_true "${CONFIG[SkipPreviouslyFailed]}" && [[ -f "$failed_path" ]]; then
        while IFS='|' read -r dns _rest; do
            dns="${dns#"${dns%%[![:space:]]*}"}"
            dns="${dns%"${dns##*[![:space:]]}"}"
            [[ -n "$dns" ]] && known_bad["$dns"]=1
        done < "$failed_path"
        log Info "Loaded ${#known_bad[@]} previously failed DNS entries to skip"
    fi

    # Filter out known-bad
    local -a filtered=()
    local skipped=0
    for dns in "${all_dns[@]}"; do
        if [[ -v "known_bad[$dns]" ]]; then
            skipped=$((skipped + 1))
        else
            filtered+=("$dns")
        fi
    done
    [[ $skipped -gt 0 ]] && log Info "Skipping $skipped previously failed DNS entries"

    # Separate known-good from rest
    local -A good_set
    for dns in "${known_good_list[@]}"; do good_set["$dns"]=1; done

    local -a prioritized=()
    local -a rest=()
    for dns in "${filtered[@]}"; do
        if [[ -v "good_set[$dns]" ]]; then
            prioritized+=("$dns")
        else
            rest+=("$dns")
        fi
    done

    # Shuffle rest if configured
    if _is_true "${CONFIG[ShuffleDns]}" && [[ ${#rest[@]} -gt 0 ]]; then
        if command -v shuf &>/dev/null; then
            mapfile -t rest < <(printf '%s\n' "${rest[@]}" | shuf)
        else
            # macOS fallback: use sort -R or awk
            mapfile -t rest < <(printf '%s\n' "${rest[@]}" | awk 'BEGIN{srand()}{print rand()"\t"$0}' | sort -n | cut -f2-)
        fi
    fi

    # Final list: prioritized first, then rest
    DNS_LIST=("${prioritized[@]}" "${rest[@]}")
    log Info "DNS queue: ${#prioritized[@]} prioritized + ${#rest[@]} others = ${#DNS_LIST[@]} total"
}
