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
    local custom_path="$1"
    local dns_path="$2"
    local results_dir="$3"

    # ── Load known-bad DNS ──
    local -A known_bad=()
    SKIPPED_COUNT=0
    local failed_path="$results_dir/dns-failed.txt"
    if _is_true "${CONFIG[SkipPreviouslyFailed]}" && [[ -f "$failed_path" ]]; then
        while IFS='|' read -r dns _rest; do
            dns="${dns#"${dns%%[![:space:]]*}"}"
            dns="${dns%"${dns##*[![:space:]]}"}"
            [[ -n "$dns" ]] && known_bad["$dns"]=1
        done < "$failed_path"
        SKIPPED_COUNT=${#known_bad[@]}
        log Debug "Loaded $SKIPPED_COUNT previously failed DNS entries to skip"
    fi

    # Track seen DNS to avoid duplicates across tiers
    local -A seen

    # ── Tier 0: User's custom DNS file ──
    local -a tier0=()
    if [[ -f "$custom_path" ]]; then
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" == \#* ]] && continue
            [[ "$line" =~ ^[0-9] ]] || continue
            if [[ -z "${known_bad[$line]+x}" && -z "${seen[$line]+x}" ]]; then
                tier0+=("$line")
                seen["$line"]=1
            fi
        done < "$custom_path"
        log Debug "Tier 0 (dns-custom.txt): ${#tier0[@]} entries"
    fi

    # ── Tier 1: Previously working DNS ──
    local -a tier1=()
    local working_path="$results_dir/dns-working.txt"
    if _is_true "${CONFIG[PrioritizeKnownGood]}" && [[ -f "$working_path" ]]; then
        while IFS='|' read -r dns _rest; do
            dns="${dns#"${dns%%[![:space:]]*}"}"
            dns="${dns%"${dns##*[![:space:]]}"}"
            if [[ -n "$dns" && -z "${known_bad[$dns]+x}" && -z "${seen[$dns]+x}" ]]; then
                tier1+=("$dns")
                seen["$dns"]=1
            fi
        done < "$working_path"
    fi
    log Debug "Tier 1 (previously working): ${#tier1[@]} entries"

    # ── Tier 2: DNS list ──
    local -a tier2=()
    if [[ -f "$dns_path" ]]; then
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" == \#* ]] && continue
            [[ "$line" =~ ^[0-9] ]] || continue
            if [[ -z "${known_bad[$line]+x}" && -z "${seen[$line]+x}" ]]; then
                tier2+=("$line")
                seen["$line"]=1
            fi
        done < "$dns_path"
    else
        log Warning "DNS list not found at $dns_path"
    fi
    log Debug "Tier 2 (dns-list.txt): ${#tier2[@]} entries"

    # ── Combine: tier0 → tier1 → tier2 ──
    DNS_LIST=()
    [[ ${#tier0[@]} -gt 0 ]] && DNS_LIST+=("${tier0[@]}")
    [[ ${#tier1[@]} -gt 0 ]] && DNS_LIST+=("${tier1[@]}")
    [[ ${#tier2[@]} -gt 0 ]] && DNS_LIST+=("${tier2[@]}")
    PRIORITY_COUNT=$(( ${#tier0[@]} + ${#tier1[@]} ))
    TIER0_COUNT=${#tier0[@]}
    TIER1_COUNT=${#tier1[@]}
    TIER2_COUNT=${#tier2[@]}
    log Debug "DNS queue: ${#DNS_LIST[@]} total (custom: ${#tier0[@]}, working: ${#tier1[@]}, list: ${#tier2[@]})"
}
