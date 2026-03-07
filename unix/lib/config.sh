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

_load_dns_file() {
    local path="$1"
    local -n _out_arr=$2

    if [[ ! -f "$path" ]]; then
        return
    fi

    mapfile -t _out_arr < <(grep -E '^\s*[0-9]' "$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')
}

_shuffle_array() {
    local -n _arr=$1

    if [[ ${#_arr[@]} -eq 0 ]]; then
        return
    fi

    if command -v shuf &>/dev/null; then
        mapfile -t _arr < <(printf '%s\n' "${_arr[@]}" | shuf)
    else
        # macOS fallback
        mapfile -t _arr < <(printf '%s\n' "${_arr[@]}" | awk 'BEGIN{srand()}{print rand()"\t"$0}' | sort -n | cut -f2-)
    fi
}

_load_tier() {
    local path="$1"
    local -n _tier_out=$2
    local -n _tier_seen=$3
    local -n _tier_bad=$4

    local -a raw=()
    _load_dns_file "$path" raw

    for dns in "${raw[@]}"; do
        if [[ ! -v "_tier_bad[$dns]" && ! -v "_tier_seen[$dns]" ]]; then
            _tier_out+=("$dns")
            _tier_seen["$dns"]=1
        fi
    done
}

read_dns_list() {
    local custom_path="$1"
    local dns_path="$2"
    local resolvers_path="$3"
    local results_dir="$4"

    # ── Load known-bad DNS ──
    local -A known_bad
    local failed_path="$results_dir/dns-failed.txt"
    if _is_true "${CONFIG[SkipPreviouslyFailed]}" && [[ -f "$failed_path" ]]; then
        while IFS='|' read -r dns _rest; do
            dns="${dns#"${dns%%[![:space:]]*}"}"
            dns="${dns%"${dns##*[![:space:]]}"}"
            [[ -n "$dns" ]] && known_bad["$dns"]=1
        done < "$failed_path"
        log Info "Loaded ${#known_bad[@]} previously failed DNS entries to skip"
    fi

    # Track seen DNS to avoid duplicates across tiers
    local -A seen

    # ── Tier 0: User's custom DNS file ──
    local -a tier0=()
    if [[ -f "$custom_path" ]]; then
        _load_tier "$custom_path" tier0 seen known_bad
        log Info "Tier 0 (dns-custom.txt): ${#tier0[@]} entries"
    fi

    # ── Tier 1: Previously working DNS ──
    local -a tier1=()
    local working_path="$results_dir/dns-working.txt"
    if _is_true "${CONFIG[PrioritizeKnownGood]}" && [[ -f "$working_path" ]]; then
        while IFS='|' read -r dns _rest; do
            dns="${dns#"${dns%%[![:space:]]*}"}"
            dns="${dns%"${dns##*[![:space:]]}"}"
            if [[ -n "$dns" && ! -v "known_bad[$dns]" && ! -v "seen[$dns]" ]]; then
                tier1+=("$dns")
                seen["$dns"]=1
            fi
        done < "$working_path"
    fi
    log Info "Tier 1 (previously working): ${#tier1[@]} entries"

    # ── Tier 2: Curated resolvers list ──
    local -a tier2=()
    _load_tier "$resolvers_path" tier2 seen known_bad

    if _is_true "${CONFIG[ShuffleDns]}" && [[ ${#tier2[@]} -gt 0 ]]; then
        _shuffle_array tier2
    fi
    log Info "Tier 2 (dns-resolvers.txt): ${#tier2[@]} entries"

    # ── Tier 3: Large DNS list ──
    local -a tier3=()

    if [[ -f "$dns_path" ]]; then
        _load_tier "$dns_path" tier3 seen known_bad
    else
        log Warning "DNS list not found at $dns_path"
    fi

    if _is_true "${CONFIG[ShuffleDns]}" && [[ ${#tier3[@]} -gt 0 ]]; then
        _shuffle_array tier3
    fi
    log Info "Tier 3 (dns-list.txt): ${#tier3[@]} entries"

    # ── Combine: tier0 → tier1 → tier2 → tier3 ──
    DNS_LIST=("${tier0[@]}" "${tier1[@]}" "${tier2[@]}" "${tier3[@]}")
    log Info "DNS queue: ${#tier0[@]} + ${#tier1[@]} + ${#tier2[@]} + ${#tier3[@]} = ${#DNS_LIST[@]} total"
}
