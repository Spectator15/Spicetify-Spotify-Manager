#!/usr/bin/env bash
# Spicetify Spotify Manager for Linux
# Copyright (c) 2026 Spectator15
# SPDX-License-Identifier: MIT

set -uo pipefail

readonly SSM_NAME="Spicetify Spotify Manager"
readonly SSM_VERSION="1.1.0"
readonly SSM_FLATPAK_ID="com.spotify.Client"
readonly SSM_APT_PACKAGE="spotify-client"
readonly SSM_INSTALLER_URL="https://raw.githubusercontent.com/spicetify/cli/main/install.sh"
readonly SSM_STATE_SCHEMA="1"

SSM_MANUAL_SPOTIFY_PATH=""
SSM_MANUAL_PREFS_PATH=""
SSM_CONTEXT_READY=0
SSM_DISTRO="Unknown Linux"
SSM_KIND="none"
SSM_SCOPE=""
SSM_SPOTIFY_PATH=""
SSM_PREFS_PATH=""
SSM_SPOTIFY_VERSION="unknown"
SSM_SUPPORT="unsupported"
SSM_CONTEXT_NOTE="Spotify was not detected."
SSM_WORKFLOW_ACTIVE=0
SSM_TEMP_DIR=""

ssm_info() { printf '%s\n' "$*"; }
ssm_success() { printf 'OK: %s\n' "$*"; }
ssm_warn() { printf 'WARNING: %s\n' "$*" >&2; }
ssm_error() { printf 'ERROR: %s\n' "$*" >&2; }

ssm_have() { command -v "$1" >/dev/null 2>&1; }

ssm_current_uid() { id -u; }

ssm_require_non_root() {
    if [[ "$(ssm_current_uid)" == "0" ]]; then
        ssm_error "Do not run the manager as root or through sudo. It requests privilege only for an exact operation that needs it."
        return 77
    fi
}

ssm_confirm() {
    local prompt=${1:?prompt required}
    local default=${2:-no}
    local answer
    if [[ ! -t 0 ]]; then
        ssm_error "Confirmation is required, but standard input is not interactive."
        return 64
    fi
    if [[ "$default" == "yes" ]]; then
        read -r -p "$prompt [Y/n] " answer || return 130
        [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
    else
        read -r -p "$prompt [y/N] " answer || return 130
        [[ "$answer" =~ ^[Yy]$ ]]
    fi
}

ssm_require_command() {
    if ! ssm_have "$1"; then
        ssm_error "Required command '$1' was not found."
        return 69
    fi
}

ssm_realpath_existing() {
    realpath -e -- "$1" 2>/dev/null
}

ssm_path_within() {
    local child parent
    child=$(ssm_realpath_existing "$1") || return 1
    parent=$(ssm_realpath_existing "$2") || return 1
    [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

ssm_path_has_symlink_component() {
    local path=${1:?path required}
    local current="/" part
    [[ "$path" == /* ]] || return 0
    IFS='/' read -r -a parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        current="${current%/}/$part"
        [[ -L "$current" ]] && return 0
    done
    return 1
}

ssm_validate_text_value() {
    local value=${1-}
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]]
}

ssm_state_directory() {
    local base
    if [[ -n "${XDG_STATE_HOME:-}" ]]; then
        base=$XDG_STATE_HOME
    else
        base=${HOME:?HOME is not set}/.local/state
    fi
    [[ "$base" == /* ]] || {
        ssm_error "XDG_STATE_HOME must be an absolute path."
        return 78
    }
    printf '%s/spicetify-spotify-manager\n' "${base%/}"
}

ssm_assert_safe_state_directory() {
    local directory parent uid mode mode_value
    directory=$(ssm_state_directory) || return
    parent=${directory%/*}
    if ssm_path_has_symlink_component "$parent"; then
        ssm_error "The manager state path contains a symlink: $parent"
        return 78
    fi
    if [[ -e "$directory" && ( -L "$directory" || ! -d "$directory" ) ]]; then
        ssm_error "The manager state path is a symlink or not a directory: $directory"
        return 78
    fi
    if [[ ! -d "$directory" ]]; then
        mkdir -p -- "$parent" || return
        if [[ -L "$parent" ]]; then
            ssm_error "The state parent directory must not be a symlink: $parent"
            return 78
        fi
        (umask 077 && mkdir -- "$directory") || return
    fi
    uid=$(stat -c '%u' -- "$directory") || return
    mode=$(stat -c '%a' -- "$directory") || return
    mode_value=$((8#$mode))
    if [[ "$uid" != "$(ssm_current_uid)" || $((mode_value & 0022)) -ne 0 ]]; then
        ssm_error "The state directory must be owned by the current user and not group/world writable: $directory"
        return 78
    fi
    chmod 700 -- "$directory" || return
    printf '%s\n' "$directory"
}

ssm_state_path() {
    local name=${1:?state name required}
    case "$name" in
        control|workflow|permissions) ;;
        *) ssm_error "Refusing an unknown state-file name: $name"; return 78 ;;
    esac
    printf '%s/%s.state\n' "$(ssm_state_directory)" "$name"
}

ssm_validate_state_file() {
    local path=${1:?path required} uid mode mode_value expected_parent actual_parent
    [[ -e "$path" ]] || return 1
    if [[ -L "$path" || ! -f "$path" ]]; then
        ssm_error "Unsafe manager state file: $path"
        return 78
    fi
    expected_parent=$(ssm_realpath_existing "$(ssm_state_directory)") || return 78
    actual_parent=$(ssm_realpath_existing "${path%/*}") || return 78
    [[ "$expected_parent" == "$actual_parent" ]] || {
        ssm_error "State file escaped the manager state directory: $path"
        return 78
    }
    uid=$(stat -c '%u' -- "$path") || return 78
    mode=$(stat -c '%a' -- "$path") || return 78
    mode_value=$((8#$mode))
    if [[ "$uid" != "$(ssm_current_uid)" || $((mode_value & 0077)) -ne 0 ]]; then
        ssm_error "State file has unsafe ownership or permissions: $path"
        return 78
    fi
}

ssm_write_state_atomic() {
    local name=${1:?state name required}
    shift
    local directory path temporary entry key value
    directory=$(ssm_assert_safe_state_directory) || return
    path="$directory/$name.state"
    temporary=$(mktemp -- "$directory/.${name}.state.XXXXXX") || return
    chmod 600 -- "$temporary" || { rm -f -- "$temporary"; return 1; }
    for entry in "$@"; do
        key=${entry%%=*}
        value=${entry#*=}
        if [[ ! "$key" =~ ^[a-z_]+$ ]] || ! ssm_validate_text_value "$value"; then
            rm -f -- "$temporary"
            ssm_error "Refusing unsafe state data."
            return 78
        fi
        printf '%s\t%s\n' "$key" "$value" >> "$temporary" || {
            rm -f -- "$temporary"
            return 1
        }
    done
    mv -f -- "$temporary" "$path" || { rm -f -- "$temporary"; return 1; }
}

ssm_remove_state() {
    local path
    path=$(ssm_state_path "$1") || return
    if [[ -e "$path" ]]; then
        ssm_validate_state_file "$path" || return
        rm -f -- "$path"
    fi
}

ssm_read_state() {
    local name=${1:?state name required}
    local path key value schema_seen=0
    path=$(ssm_state_path "$name") || return
    [[ -e "$path" ]] || return 1
    ssm_validate_state_file "$path" || return
    SSM_STATE_KIND=""; SSM_STATE_SCOPE=""; SSM_STATE_OWNER=""
    SSM_STATE_TARGET=""; SSM_STATE_PHASE=""; SSM_STATE_PREVIOUS=""
    SSM_STATE_RUNNING="0"; SSM_STATE_LAUNCH=""; SSM_STATE_PATH=""
    while IFS=$'\t' read -r key value || [[ -n "$key" ]]; do
        [[ -n "$key" && -n "${value+x}" ]] || { ssm_error "Malformed state file: $path"; return 78; }
        ssm_validate_text_value "$value" || { ssm_error "Malformed state value in $path"; return 78; }
        case "$key" in
            schema) [[ "$value" == "$SSM_STATE_SCHEMA" ]] || { ssm_error "Unsupported state schema in $path"; return 78; }; schema_seen=1 ;;
            kind) SSM_STATE_KIND=$value ;;
            scope) SSM_STATE_SCOPE=$value ;;
            owner) SSM_STATE_OWNER=$value ;;
            target) SSM_STATE_TARGET=$value ;;
            phase) SSM_STATE_PHASE=$value ;;
            previous) SSM_STATE_PREVIOUS=$value ;;
            running) [[ "$value" =~ ^[01]$ ]] || { ssm_error "Invalid running value in $path"; return 78; }; SSM_STATE_RUNNING=$value ;;
            launch) SSM_STATE_LAUNCH=$value ;;
            path) SSM_STATE_PATH=$value ;;
            *) ssm_error "Unknown state key '$key' in $path"; return 78 ;;
        esac
    done < "$path"
    [[ "$schema_seen" == 1 ]] || { ssm_error "State schema is missing in $path"; return 78; }
}

ssm_read_os_release() {
    local key value name="" pretty=""
    [[ -r /etc/os-release ]] || { printf 'Unknown Linux\n'; return; }
    while IFS='=' read -r key value; do
        value=${value%$'\r'}
        value=${value#\"}; value=${value%\"}
        value=${value#\'}; value=${value%\'}
        case "$key" in
            PRETTY_NAME) pretty=$value ;;
            NAME) name=$value ;;
        esac
    done < /etc/os-release
    printf '%s\n' "${pretty:-${name:-Unknown Linux}}"
}

ssm_nix_detected() {
    [[ -e /etc/NIXOS ]] || {
        ssm_have readlink && [[ "$(readlink -f "$(command -v spotify 2>/dev/null || printf /nonexistent)")" == /nix/store/* ]]
    }
}

ssm_first_package_spotify_path() {
    local manager=$1 line candidate
    if [[ "$manager" == "apt" ]]; then
        while IFS= read -r line; do
            [[ "$line" == */Apps || "$line" == */Apps/ ]] || continue
            candidate=${line%/Apps}; candidate=${candidate%/Apps/}
            [[ -d "$candidate/Apps" ]] && { printf '%s\n' "$candidate"; return 0; }
        done < <(dpkg-query -L "$SSM_APT_PACKAGE" 2>/dev/null)
    else
        while IFS= read -r line; do
            candidate=${line#* }
            [[ "$candidate" == */Apps/ || "$candidate" == */Apps ]] || continue
            candidate=${candidate%/Apps}; candidate=${candidate%/Apps/}
            [[ -d "$candidate/Apps" ]] && { printf '%s\n' "$candidate"; return 0; }
        done < <(pacman -Ql spotify 2>/dev/null)
    fi
    return 1
}

ssm_validate_spotify_resources() {
    local path=${1:?Spotify path required}
    local allow_symlink=${2:-0}
    [[ "$path" == /* && -d "$path" && -d "$path/Apps" ]] || return 1
    [[ -f "$path/Apps/xpui.spa" || -d "$path/Apps/xpui" ]] || return 1
    if [[ "$allow_symlink" != 1 ]] && ssm_path_has_symlink_component "$path"; then
        return 1
    fi
    ssm_realpath_existing "$path" >/dev/null
}

ssm_detect_context() {
    SSM_CONTEXT_READY=0
    SSM_DISTRO=$(ssm_read_os_release)
    SSM_KIND="none"; SSM_SCOPE=""; SSM_SPOTIFY_PATH=""; SSM_PREFS_PATH=""
    SSM_SPOTIFY_VERSION="unknown"; SSM_SUPPORT="unsupported"; SSM_CONTEXT_NOTE="Spotify was not detected."
    local candidates=0 flatpak_user=0 flatpak_system=0 apt_found=0 arch_found=0 launcher_found=0 snap_found=0 nix_found=0
    local location output version path

    if [[ -n "$SSM_MANUAL_SPOTIFY_PATH" ]]; then
        if [[ -L "$SSM_MANUAL_SPOTIFY_PATH" ]] || ssm_path_has_symlink_component "$SSM_MANUAL_SPOTIFY_PATH"; then
            SSM_CONTEXT_NOTE="The supplied manual Spotify path contains a symlink and was refused."
            SSM_CONTEXT_READY=1; return 0
        fi
        path=$(ssm_realpath_existing "$SSM_MANUAL_SPOTIFY_PATH") || {
            SSM_CONTEXT_NOTE="The supplied manual Spotify path does not exist."
            SSM_CONTEXT_READY=1; return 0
        }
        if ! ssm_validate_spotify_resources "$path"; then
            SSM_CONTEXT_NOTE="The supplied manual path is unsafe or does not contain verified Spotify Apps resources."
            SSM_CONTEXT_READY=1; return 0
        fi
        SSM_KIND="manual"; SSM_SCOPE="manual"; SSM_SPOTIFY_PATH=$path
        if [[ -n "$SSM_MANUAL_PREFS_PATH" ]]; then
            [[ "$SSM_MANUAL_PREFS_PATH" == /* && -f "$SSM_MANUAL_PREFS_PATH" && ! -L "$SSM_MANUAL_PREFS_PATH" ]] || {
                SSM_CONTEXT_NOTE="The supplied manual preferences path is unsafe or missing."
                SSM_CONTEXT_READY=1; return 0
            }
            SSM_PREFS_PATH=$(ssm_realpath_existing "$SSM_MANUAL_PREFS_PATH")
        fi
        SSM_SUPPORT="repair-only"
        SSM_CONTEXT_NOTE="Manual path verified. Package-manager update control is unavailable."
        SSM_CONTEXT_READY=1; return 0
    fi

    if ssm_have flatpak; then
        flatpak info --user "$SSM_FLATPAK_ID" >/dev/null 2>&1 && flatpak_user=1
        flatpak info --system "$SSM_FLATPAK_ID" >/dev/null 2>&1 && flatpak_system=1
    fi
    (( flatpak_user == 1 )) && ((candidates+=1))
    (( flatpak_system == 1 )) && ((candidates+=1))

    if ssm_have dpkg-query; then
        output=$(dpkg-query -W -f='${db:Status-Status}\t${Version}\n' "$SSM_APT_PACKAGE" 2>/dev/null || true)
        [[ "$output" =~ ^installed$'\t'([0-9A-Za-z.+:~_-]+)$ ]] && apt_found=1 && ((candidates+=1))
    fi
    if ssm_have pacman; then
        pacman -Q spotify >/dev/null 2>&1 && arch_found=1 && ((candidates+=1))
        pacman -Q spotify-launcher >/dev/null 2>&1 && launcher_found=1
    fi
    if ssm_have spotify-launcher || [[ -d "${XDG_DATA_HOME:-${HOME:-}/.local/share}/spotify-launcher/install/usr/share/spotify/Apps" ]]; then
        launcher_found=1
    fi
    (( launcher_found == 1 )) && ((candidates+=1))
    if ssm_have snap && snap list spotify >/dev/null 2>&1; then snap_found=1; ((candidates+=1)); fi
    if ssm_nix_detected; then
        nix_found=1; ((candidates+=1))
    fi

    if (( flatpak_user == 1 && flatpak_system == 1 )); then
        SSM_KIND="ambiguous"; SSM_CONTEXT_NOTE="Spotify Flatpak is installed in both user and system scopes. Remove one installation or select a manual path."
        SSM_CONTEXT_READY=1; return 0
    fi
    if (( candidates > 1 )); then
        SSM_KIND="ambiguous"; SSM_CONTEXT_NOTE="Multiple Spotify installations were detected. The manager will not select one silently."
        SSM_CONTEXT_READY=1; return 0
    fi
    if (( candidates == 0 )); then SSM_CONTEXT_READY=1; return 0; fi

    if (( flatpak_user == 1 || flatpak_system == 1 )); then
        SSM_KIND="flatpak"; [[ "$flatpak_user" == 1 ]] && SSM_SCOPE="user" || SSM_SCOPE="system"
        location=$(flatpak info "--$SSM_SCOPE" --show-location "$SSM_FLATPAK_ID" 2>/dev/null || true)
        version=$(flatpak info "--$SSM_SCOPE" --show-version "$SSM_FLATPAK_ID" 2>/dev/null || true)
        path="$location/files/extra/share/spotify"
        if [[ "$location" != /* ]] || ! ssm_path_within "$path" "$location" || ! ssm_validate_spotify_resources "$path"; then
            SSM_SUPPORT="unsupported"; SSM_CONTEXT_NOTE="Flatpak was detected, but its Spotify resource path could not be verified."
        else
            SSM_SPOTIFY_PATH=$(ssm_realpath_existing "$path")
            SSM_PREFS_PATH="${HOME:?}/.var/app/$SSM_FLATPAK_ID/config/spotify/prefs"
            SSM_SPOTIFY_VERSION=${version:-unknown}; SSM_SUPPORT="full"
            SSM_CONTEXT_NOTE="Flatpak supports exact-scope masking and guided Spotify-only updates."
        fi
    elif (( apt_found == 1 )); then
        SSM_KIND="apt"; SSM_SCOPE="system"
        path=$(ssm_first_package_spotify_path apt || true)
        version=${output#*$'\t'}
        if [[ -z "$path" ]] || ! ssm_validate_spotify_resources "$path"; then
            SSM_CONTEXT_NOTE="The APT package is installed, but its Spotify resources could not be verified from dpkg."
        else
            SSM_SPOTIFY_PATH=$(ssm_realpath_existing "$path")
            SSM_PREFS_PATH="${HOME:?}/.config/spotify/prefs"; SSM_SPOTIFY_VERSION=${version:-unknown}; SSM_SUPPORT="full"
            SSM_CONTEXT_NOTE="APT hold control and Spotify-only guided updates are supported."
        fi
    elif (( arch_found == 1 )); then
        SSM_KIND="arch"; SSM_SCOPE="system"
        output=$(pacman -Q spotify 2>/dev/null || true); version=${output#* }
        path=$(ssm_first_package_spotify_path arch || true)
        if [[ -z "$path" ]] || ! ssm_validate_spotify_resources "$path"; then
            SSM_CONTEXT_NOTE="The Arch/AUR package is installed, but its Spotify resources could not be verified from pacman."
        else
            SSM_SPOTIFY_PATH=$(ssm_realpath_existing "$path")
            SSM_PREFS_PATH="${HOME:?}/.config/spotify/prefs"; SSM_SPOTIFY_VERSION=${version:-unknown}; SSM_SUPPORT="repair-only"
            SSM_CONTEXT_NOTE="Spicetify repair is supported. Updates remain managed by the normal Arch/AUR workflow."
        fi
    elif (( launcher_found == 1 )); then
        SSM_KIND="launcher"; SSM_SCOPE="user"
        path="${XDG_DATA_HOME:-${HOME:?}/.local/share}/spotify-launcher/install/usr/share/spotify"
        if ! ssm_validate_spotify_resources "$path"; then
            SSM_CONTEXT_NOTE="spotify-launcher was detected, but its installed Spotify resources are missing or unsafe. Run it once to install Spotify."
        else
            SSM_SPOTIFY_PATH=$(ssm_realpath_existing "$path")
            SSM_PREFS_PATH="${HOME:?}/.config/spotify/prefs"; SSM_SUPPORT="launch-control"
            local state_file="${XDG_DATA_HOME:-${HOME:?}/.local/share}/spotify-launcher/state.json"
            if [[ -r "$state_file" ]]; then
                version=$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"[:cntrl:]]+)".*/\1/p' "$state_file" | head -n 1)
                SSM_SPOTIFY_VERSION=${version:-unknown}
            fi
            SSM_CONTEXT_NOTE="Update skipping applies only to spotify-launcher starts made through this manager."
        fi
    elif (( snap_found == 1 )); then
        SSM_KIND="snap"; SSM_SCOPE="system"; SSM_CONTEXT_NOTE="Snap Spotify is unsupported because its application files cannot be modified by Spicetify."
    elif (( nix_found == 1 )); then
        SSM_KIND="nix"; SSM_SCOPE="declarative"; SSM_CONTEXT_NOTE="Nix-managed Spotify should be configured declaratively with spicetify-nix."
    fi
    SSM_CONTEXT_READY=1
}

ssm_context_label() {
    case "$SSM_KIND" in
        flatpak) printf 'Flatpak (%s)\n' "$SSM_SCOPE" ;;
        apt) printf 'APT spotify-client\n' ;;
        arch) printf 'Arch/AUR package\n' ;;
        launcher) printf 'spotify-launcher\n' ;;
        snap) printf 'Snap (unsupported)\n' ;;
        nix) printf 'Nix/NixOS (use spicetify-nix)\n' ;;
        manual) printf 'Manual path (repair only)\n' ;;
        ambiguous) printf 'Ambiguous\n' ;;
        *) printf 'Not found\n' ;;
    esac
}

ssm_spotify_pids() {
    ssm_have pgrep || return 1
    pgrep -u "$(ssm_current_uid)" -x spotify 2>/dev/null | while IFS= read -r pid; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] && printf '%s\n' "$pid"
    done
}

ssm_spotify_running() { [[ -n "$(ssm_spotify_pids || true)" ]]; }

ssm_wait_for_spotify_state() {
    local expected=${1:?expected state required}
    local attempts=0 running=0
    while (( attempts < 60 )); do
        ssm_spotify_running && running=1 || running=0
        [[ "$running" == "$expected" ]] && return 0
        sleep 0.25
        ((attempts+=1))
    done
    return 75
}

ssm_stop_spotify() {
    local pids pid remaining
    pids=$(ssm_spotify_pids || true)
    [[ -n "$pids" ]] || return 0
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
    local attempts=0
    while (( attempts < 40 )); do
        remaining=$(ssm_spotify_pids || true)
        [[ -z "$remaining" ]] && return 0
        sleep 0.25
        ((attempts+=1))
    done
    ssm_error "Spotify did not close after a polite termination request. No unrelated process was killed."
    return 75
}

ssm_launcher_skip_enabled() {
    if ssm_read_state control 2>/dev/null && [[ "$SSM_STATE_KIND" == "launcher" && "$SSM_STATE_OWNER" == "manager" ]]; then return 0; fi
    return 1
}

ssm_start_spotify() {
    case "$SSM_KIND" in
        flatpak) nohup flatpak run "$SSM_FLATPAK_ID" >/dev/null 2>&1 & ;;
        launcher)
            local args=()
            ssm_launcher_skip_enabled && args+=(--skip-update)
            nohup spotify-launcher "${args[@]}" >/dev/null 2>&1 &
            ;;
        apt|arch|manual)
            if [[ -x "$SSM_SPOTIFY_PATH/spotify" ]]; then nohup "$SSM_SPOTIFY_PATH/spotify" >/dev/null 2>&1 &
            elif ssm_have spotify; then nohup spotify >/dev/null 2>&1 &
            else ssm_error "A safe Spotify launch command was not found."; return 69
            fi
            ;;
        *) ssm_error "Spotify cannot be launched for this installation type."; return 69 ;;
    esac
    if ! ssm_wait_for_spotify_state 1; then
        ssm_error "Spotify was launched, but a matching Spotify process was not observed."
        return 75
    fi
}

ssm_flatpak_masked() {
    local output result
    output=$(flatpak mask "--$SSM_SCOPE" 2>&1)
    result=$?
    if (( result != 0 )); then
        ssm_error "Could not read the Flatpak mask state: ${output:-no diagnostic output}"
        return 70
    fi
    grep -Fqx -- "$SSM_FLATPAK_ID" <<< "$output"
}

ssm_apt_held() {
    local output result
    output=$(apt-mark showhold 2>&1)
    result=$?
    if (( result != 0 )); then
        ssm_error "Could not read the APT hold state: ${output:-no diagnostic output}"
        return 70
    fi
    grep -Fqx -- "$SSM_APT_PACKAGE" <<< "$output"
}

ssm_control_owned_for_context() {
    ssm_read_state control 2>/dev/null || return 1
    [[ "$SSM_STATE_OWNER" == manager && "$SSM_STATE_KIND" == "$SSM_KIND" && "$SSM_STATE_SCOPE" == "$SSM_SCOPE" && "$SSM_STATE_TARGET" == "$(ssm_control_target)" ]]
}

ssm_control_target() {
    case "$SSM_KIND" in
        flatpak) printf '%s\n' "$SSM_FLATPAK_ID" ;;
        apt) printf '%s\n' "$SSM_APT_PACKAGE" ;;
        launcher) printf '%s\n' spotify-launcher ;;
        *) printf '%s\n' unavailable ;;
    esac
}

ssm_update_state() {
    local physically_allowed=1 query_result=0
    case "$SSM_KIND" in
        flatpak)
            ssm_flatpak_masked
            query_result=$?
            ;;
        apt)
            ssm_apt_held
            query_result=$?
            ;;
        launcher) ssm_launcher_skip_enabled && physically_allowed=0 ;;
        arch|manual) printf 'externally-managed\n'; return ;;
        *) printf 'unavailable\n'; return ;;
    esac
    if [[ "$SSM_KIND" == flatpak || "$SSM_KIND" == apt ]]; then
        case "$query_result" in
            0) physically_allowed=0 ;;
            1) physically_allowed=1 ;;
            *) printf 'unknown\n'; return 70 ;;
        esac
    fi
    if ssm_control_owned_for_context; then
        if (( physically_allowed == 0 )); then printf 'blocked-manager\n'; else printf 'recovery-required\n'; fi
    elif ssm_read_state control >/dev/null 2>&1; then
        printf 'recovery-required\n'
    elif (( physically_allowed == 0 )); then
        printf 'blocked-external\n'
    else
        printf 'allowed\n'
    fi
}

ssm_run_privileged() {
    ssm_require_command sudo || return
    sudo -- "$@"
}

ssm_set_control_raw() {
    local blocked=${1:?blocked value required} command_result=0
    case "$SSM_KIND" in
        flatpak)
            if [[ "$blocked" == 1 ]]; then flatpak mask "--$SSM_SCOPE" "$SSM_FLATPAK_ID" || command_result=$?
            else flatpak mask "--$SSM_SCOPE" --remove "$SSM_FLATPAK_ID" || command_result=$?
            fi
            ;;
        apt)
            if [[ "$blocked" == 1 ]]; then ssm_run_privileged apt-mark hold "$SSM_APT_PACKAGE" || command_result=$?
            else ssm_run_privileged apt-mark unhold "$SSM_APT_PACKAGE" || command_result=$?
            fi
            ;;
        *) ssm_error "Persistent package update control is unavailable for $(ssm_context_label)."; return 69 ;;
    esac
    (( command_result == 0 )) || return 70
    if [[ "$blocked" == 1 ]]; then
        case "$SSM_KIND" in flatpak) ssm_flatpak_masked;; apt) ssm_apt_held;; esac
    else
        case "$SSM_KIND" in flatpak) ! ssm_flatpak_masked;; apt) ! ssm_apt_held;; esac
    fi
}

ssm_block_updates() {
    local current query_result recovered_result
    current=$(ssm_update_state)
    query_result=$?
    (( query_result == 0 )) || return "$query_result"
    case "$SSM_KIND" in
        launcher)
            if [[ "$current" == blocked-manager ]]; then ssm_info "spotify-launcher update skipping is already enabled for manager-started launches."; return 0; fi
            if [[ "$current" == recovery-required ]]; then ssm_error "Resolve the saved control-state mismatch first."; return 78; fi
            ssm_write_state_atomic control "schema=$SSM_STATE_SCHEMA" "kind=launcher" "scope=user" "owner=manager" "target=spotify-launcher" "phase=blocked" || return
            ssm_success "Manager-started spotify-launcher sessions will use --skip-update. Other launch methods are unaffected."
            return 0
            ;;
        flatpak|apt) ;;
        *) ssm_error "Update control is unavailable for $(ssm_context_label). $SSM_CONTEXT_NOTE"; return 69 ;;
    esac
    case "$current" in
        blocked-manager) ssm_info "Spotify updates are already blocked by this manager."; return 0 ;;
        blocked-external) ssm_info "Spotify updates are already controlled outside this manager. That state was preserved."; return 0 ;;
        recovery-required) ssm_error "The saved control state does not match the package manager. Use recovery before changing it."; return 78 ;;
    esac
    ssm_write_state_atomic control "schema=$SSM_STATE_SCHEMA" "kind=$SSM_KIND" "scope=$SSM_SCOPE" "owner=manager" "target=$(ssm_control_target)" "phase=applying" || return
    if ! ssm_set_control_raw 1; then
        ssm_error "Could not block Spotify updates. The package-manager error is shown above."
        ssm_warn "Attempting to restore the previously allowed state."
        if ssm_set_control_raw 0; then
            ssm_remove_state control || true
            ssm_warn "The previously allowed state was restored."
        else
            case "$SSM_KIND" in
                flatpak) ssm_flatpak_masked; recovered_result=$? ;;
                apt) ssm_apt_held; recovered_result=$? ;;
            esac
            if (( recovered_result == 1 )); then
                ssm_remove_state control || true
                ssm_warn "The package command failed, but the previously allowed state was independently verified."
            else
                ssm_error "Automatic recovery could not be verified. Recovery state was retained for the next run."
            fi
        fi
        return 70
    fi
    ssm_write_state_atomic control "schema=$SSM_STATE_SCHEMA" "kind=$SSM_KIND" "scope=$SSM_SCOPE" "owner=manager" "target=$(ssm_control_target)" "phase=blocked" || return
    [[ "$(ssm_update_state)" == blocked-manager ]] || { ssm_error "The requested control state could not be verified."; return 70; }
    ssm_success "Spotify updates are blocked through the exact $SSM_KIND target."
}

ssm_allow_updates() {
    local current query_result
    current=$(ssm_update_state)
    query_result=$?
    (( query_result == 0 )) || return "$query_result"
    case "$SSM_KIND" in
        launcher)
            if [[ "$current" == blocked-manager ]]; then ssm_remove_state control || return; ssm_success "Manager-started spotify-launcher sessions may update again."; return 0; fi
            [[ "$current" == allowed ]] && { ssm_info "Manager-started spotify-launcher sessions are already allowed to update."; return 0; }
            ;;
        flatpak|apt) ;;
        *) ssm_error "Update control is unavailable for $(ssm_context_label)."; return 69 ;;
    esac
    case "$current" in
        allowed) ssm_info "Spotify updates are already allowed."; return 0 ;;
        blocked-external) ssm_warn "Spotify is blocked outside this manager. It will not remove someone else's mask or hold."; return 0 ;;
        recovery-required) ssm_error "The saved manager state and package-manager state disagree. Use recovery."; return 78 ;;
        blocked-manager) ;;
        *) return 69 ;;
    esac
    if ! ssm_set_control_raw 0; then
        ssm_error "Could not allow Spotify updates. The saved ownership record was retained for recovery."
        return 70
    fi
    ssm_remove_state control || return
    [[ "$(ssm_update_state)" == allowed ]] || { ssm_error "Allowed state could not be verified."; return 70; }
    ssm_success "Spotify updates are allowed. Only this manager's control was removed."
}

ssm_spicetify_executable() {
    local candidate
    candidate=$(command -v spicetify 2>/dev/null || true)
    [[ -n "$candidate" ]] || candidate="${HOME:-}/.spicetify/spicetify"
    [[ -x "$candidate" ]] && ssm_realpath_existing "$candidate"
}

ssm_spicetify_version() {
    local executable output
    executable=$(ssm_spicetify_executable || true)
    [[ -n "$executable" ]] || { printf 'not installed\n'; return; }
    output=$("$executable" -v 2>/dev/null | head -n 1)
    printf '%s\n' "${output:-installed, version unknown}"
}

ssm_ini_value() {
    local file=$1 section=$2 key=$3 current="" line name value
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then current=${BASH_REMATCH[1]}; continue; fi
        [[ "$current" == "$section" && "$line" == *"="* ]] || continue
        name=${line%%=*}; value=${line#*=}
        name=${name//[[:space:]]/}
        if [[ "$name" == "$key" ]]; then
            value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}
            printf '%s\n' "$value"; return 0
        fi
    done < "$file"
    return 1
}

ssm_preferences_version() {
    local line value
    [[ -r "$SSM_PREFS_PATH" ]] || return 1
    line=$(grep -m1 '^app\.last-launched-version=' "$SSM_PREFS_PATH" 2>/dev/null || true)
    value=${line#*=}; value=${value#\"}; value=${value%\"}
    [[ -n "$line" && -n "$value" ]] && printf '%s\n' "$value"
}

ssm_spicetify_state() {
    local executable config_dir config backup spotify_version configured_path configured_prefs
    executable=$(ssm_spicetify_executable || true)
    [[ -n "$executable" ]] || { printf 'missing\n'; return; }
    if [[ -d "$SSM_SPOTIFY_PATH/Apps/xpui" && ! -f "$SSM_SPOTIFY_PATH/Apps/xpui.spa" ]]; then
        config_dir=$("$executable" path userdata 2>/dev/null | tail -n 1 || true)
        config="$config_dir/config-xpui.ini"
        backup=$(ssm_ini_value "$config" Backup version 2>/dev/null || true)
        spotify_version=$(ssm_preferences_version 2>/dev/null || true)
        configured_path=$(ssm_ini_value "$config" Setting spotify_path 2>/dev/null || true)
        configured_prefs=$(ssm_ini_value "$config" Setting prefs_path 2>/dev/null || true)
        if [[ -n "$spotify_version" && -n "$backup" && "$spotify_version" != "$backup" ]]; then printf 'stale\n'
        elif [[ "$configured_path" != "$SSM_SPOTIFY_PATH" || "$configured_prefs" != "$SSM_PREFS_PATH" ]]; then printf 'stale\n'
        else printf 'applied\n'; fi
    elif [[ -f "$SSM_SPOTIFY_PATH/Apps/xpui.spa" && ! -d "$SSM_SPOTIFY_PATH/Apps/xpui" ]]; then printf 'unapplied\n'
    else printf 'unknown\n'; fi
}

ssm_spicetify_package_owner() {
    local executable owner
    executable=$(ssm_spicetify_executable || true); [[ -n "$executable" ]] || return 1
    if ssm_have dpkg-query; then
        owner=$(dpkg-query -S "$executable" 2>/dev/null | head -n 1 || true)
        [[ -n "$owner" ]] && { printf 'apt:%s\n' "${owner%%:*}"; return; }
    fi
    if ssm_have pacman; then
        owner=$(pacman -Qo "$executable" 2>/dev/null || true)
        [[ "$owner" =~ " is owned by "([^[:space:]]+) ]] && { printf 'pacman:%s\n' "${BASH_REMATCH[1]}"; return; }
    fi
    [[ "$executable" == "$HOME/.spicetify/"* ]] && { printf 'official\n'; return; }
    printf 'unknown\n'
}

ssm_install_or_update_spicetify() {
    local executable owner temp installer content
    executable=$(ssm_spicetify_executable || true)
    if [[ -n "$executable" ]]; then
        owner=$(ssm_spicetify_package_owner)
        case "$owner" in
            official)
                "$executable" update --no-restart || { ssm_error "Spicetify's supported update command failed."; return 70; }
                ssm_success "Spicetify's update check completed."
                ;;
            unknown)
                ssm_warn "The installed Spicetify executable is not owned by a recognized package or the official ~/.spicetify installation. Update it through its original installation method."
                return 69
                ;;
            apt:*)
                local package=${owner#apt:}
                ssm_confirm "Update package-managed Spicetify package '$package' with APT?" || return 0
                ssm_run_privileged apt-get install --only-upgrade -- "$package" || return 70
                ssm_success "The package-managed Spicetify update completed."
                ;;
            pacman:*)
                ssm_warn "Spicetify is owned by ${owner#pacman:}. Update it through your normal complete Arch/AUR update workflow."
                return 69
                ;;
        esac
        ssm_spicetify_executable >/dev/null || { ssm_error "Spicetify could not be verified after updating."; return 70; }
        return 0
    fi
    ssm_require_command curl || return
    temp=$(mktemp -d -- "${TMPDIR:-/tmp}/spicetify-manager-install.XXXXXX") || return
    SSM_TEMP_DIR=$temp; installer="$temp/install.sh"
    if ! curl --fail --location --proto '=https' --tlsv1.2 --output "$installer" "$SSM_INSTALLER_URL"; then
        ssm_error "The official installer download failed."; ssm_cleanup_temp; return 70
    fi
    content=$(head -n 2 "$installer" 2>/dev/null || true)
    if [[ ! -s "$installer" || "$content" != *"#!/usr/bin/env sh"* ]] || ! grep -Fq 'github.com/spicetify/cli/releases' "$installer"; then
        ssm_error "The downloaded file did not match the expected official shell installer."; ssm_cleanup_temp; return 70
    fi
    ssm_info "Official source: $SSM_INSTALLER_URL"
    ssm_info "The upstream installer may separately offer Marketplace. It is not installed unless you explicitly accept that upstream prompt."
    if ! ssm_confirm "Run the saved official Spicetify installer now?"; then ssm_cleanup_temp; return 0; fi
    (cd -- "$temp" && sh "$installer") || { ssm_error "The saved official Spicetify installer failed."; ssm_cleanup_temp; return 70; }
    ssm_cleanup_temp
    ssm_spicetify_executable >/dev/null || { ssm_error "The installer completed, but the Spicetify CLI was not found."; return 70; }
    ssm_success "Spicetify was installed from the official project and verified."
}

ssm_permissions_manifest_path() { ssm_state_path permissions; }

ssm_prepare_write_access() {
    if [[ -w "$SSM_SPOTIFY_PATH" && -w "$SSM_SPOTIFY_PATH/Apps" ]] &&
        [[ -z "$(find "$SSM_SPOTIFY_PATH/Apps" -xdev ! -writable -print -quit 2>/dev/null)" ]]; then
        return 0
    fi
    case "$SSM_KIND:$SSM_SCOPE" in
        apt:*|arch:*|flatpak:system) ;;
        *) ssm_error "Spotify resources are not writable. Refusing privilege for this installation type."; return 77 ;;
    esac
    ssm_confirm "Temporarily grant write access only to '$SSM_SPOTIFY_PATH' and its Apps directory?" || return 77
    local directory manifest temporary item mode uid gid
    directory=$(ssm_assert_safe_state_directory) || return
    manifest="$directory/permissions.state"
    temporary=$(mktemp -- "$directory/.permissions.state.XXXXXX") || return
    chmod 600 -- "$temporary" || return
    printf 'schema\t%s\nkind\t%s\nscope\t%s\npath\t%s\n' "$SSM_STATE_SCHEMA" "$SSM_KIND" "$SSM_SCOPE" "$SSM_SPOTIFY_PATH" > "$temporary"
    while IFS= read -r -d '' item; do
        ssm_validate_text_value "$item" || { rm -f -- "$temporary"; ssm_error "A Spotify path contains unsupported control characters."; return 78; }
        mode=$(stat -c '%a' -- "$item") || { rm -f -- "$temporary"; return 1; }
        uid=$(stat -c '%u' -- "$item") || { rm -f -- "$temporary"; return 1; }
        gid=$(stat -c '%g' -- "$item") || { rm -f -- "$temporary"; return 1; }
        printf 'entry\t%s\t%s\t%s\t%s\n' "$mode" "$uid" "$gid" "$item" >> "$temporary"
    done < <(printf '%s\0' "$SSM_SPOTIFY_PATH"; find "$SSM_SPOTIFY_PATH/Apps" -xdev -print0)
    mv -f -- "$temporary" "$manifest" || return
    ssm_run_privileged chmod a+rw "$SSM_SPOTIFY_PATH" || return
    ssm_run_privileged find "$SSM_SPOTIFY_PATH/Apps" -xdev ! -type l -exec chmod a+rwX -- '{}' + || return
    [[ -w "$SSM_SPOTIFY_PATH/Apps" ]] || { ssm_error "Temporary Spotify write access could not be verified."; return 77; }
}

ssm_restore_write_access() {
    local manifest key value mode saved_uid saved_gid item current_mode current_uid current_gid
    local -a entries=()
    manifest=$(ssm_permissions_manifest_path) || return
    [[ -e "$manifest" ]] || return 0
    ssm_validate_state_file "$manifest" || return
    while IFS=$'\t' read -r key value saved_uid saved_gid item || [[ -n "$key" ]]; do
        case "$key" in
            schema) [[ "$value" == "$SSM_STATE_SCHEMA" ]] || return 78 ;;
            kind) [[ "$value" == "$SSM_KIND" ]] || return 78 ;;
            scope) [[ "$value" == "$SSM_SCOPE" ]] || return 78 ;;
            path) [[ "$value" == "$SSM_SPOTIFY_PATH" ]] || return 78 ;;
            entry)
                mode=$value
                [[ "$mode" =~ ^[0-7]{3,4}$ && "$saved_uid" =~ ^[0-9]+$ && "$saved_gid" =~ ^[0-9]+$ ]] || return 78
                [[ -e "$item" && ! -L "$item" ]] || continue
                if [[ "$item" != "$SSM_SPOTIFY_PATH" ]] && ! ssm_path_within "$item" "$SSM_SPOTIFY_PATH/Apps"; then
                    ssm_error "Permission recovery refused a path outside Spotify Apps: $item"; return 78
                fi
                entries+=("$mode" "$saved_uid" "$saved_gid" "$item")
                ;;
            *) ssm_error "Malformed permission recovery state."; return 78 ;;
        esac
    done < "$manifest"
    ssm_run_privileged find "$SSM_SPOTIFY_PATH/Apps" -xdev ! -type l -exec chmod go-w -- '{}' + || return
    local index
    for ((index=0; index<${#entries[@]}; index+=4)); do
        mode=${entries[index]}; saved_uid=${entries[index+1]}; saved_gid=${entries[index+2]}; item=${entries[index+3]}
        ssm_run_privileged chmod "$mode" "$item" || return
        current_mode=$(stat -c '%a' -- "$item") || return
        current_uid=$(stat -c '%u' -- "$item") || return
        current_gid=$(stat -c '%g' -- "$item") || return
        [[ "$current_mode" == "$mode" && "$current_uid" == "$saved_uid" && "$current_gid" == "$saved_gid" ]] || {
            ssm_error "Permissions or ownership could not be restored for $item"; return 78
        }
    done
    rm -f -- "$manifest"
}

ssm_configure_spicetify() {
    local executable
    executable=$(ssm_spicetify_executable || true)
    [[ -n "$executable" ]] || { ssm_error "Spicetify is not installed."; return 69; }
    [[ -n "$SSM_SPOTIFY_PATH" && -n "$SSM_PREFS_PATH" && -f "$SSM_PREFS_PATH" && ! -L "$SSM_PREFS_PATH" ]] || {
        ssm_error "Spotify resources or the preferences file are missing. Open Spotify once, close it, and try again."
        return 69
    }
    "$executable" config spotify_path "$SSM_SPOTIFY_PATH" prefs_path "$SSM_PREFS_PATH" || {
        ssm_error "Spicetify could not save the verified absolute paths."
        return 70
    }
}

ssm_repair_spicetify() {
    local executable initial result=0
    [[ "$SSM_SUPPORT" == full || "$SSM_SUPPORT" == repair-only || "$SSM_SUPPORT" == launch-control ]] || {
        ssm_error "$SSM_CONTEXT_NOTE"; return 69
    }
    if [[ "$SSM_KIND" == manual ]]; then
        ssm_confirm "Use the verified manual Spotify path '$SSM_SPOTIFY_PATH' for this repair?" || return 64
    fi
    executable=$(ssm_spicetify_executable || true)
    [[ -n "$executable" ]] || { ssm_error "Spicetify is not installed. Use menu action 2 first."; return 69; }
    ssm_configure_spicetify || return
    initial=$(ssm_spicetify_state)
    [[ "$initial" == applied ]] && { ssm_info "Spicetify already appears applied to the current Spotify version."; return 0; }
    ssm_prepare_write_access || return
    if ! "$executable" backup apply --no-restart; then
        ssm_warn "Normal backup/apply failed. Trying the official restore, backup and apply recovery sequence."
        "$executable" restore backup apply --no-restart || result=$?
    fi
    if ! ssm_restore_write_access; then
        ssm_error "Spicetify finished, but original Spotify permissions could not be fully restored. Recovery state was retained."
        return 70
    fi
    (( result == 0 )) || { ssm_error "Spicetify repair failed. Its diagnostic output is shown above."; return 70; }
    [[ "$(ssm_spicetify_state)" == applied ]] || { ssm_error "Spicetify did not reach a verified applied state."; return 70; }
    ssm_success "Spicetify was applied and the resulting state was verified."
}

ssm_package_update() {
    case "$SSM_KIND" in
        flatpak) flatpak update "--$SSM_SCOPE" --assumeyes "$SSM_FLATPAK_ID" ;;
        apt) ssm_run_privileged apt-get install --only-upgrade -- "$SSM_APT_PACKAGE" ;;
        launcher) spotify-launcher --check-update --no-exec ;;
        arch)
            ssm_info "Arch supports complete system upgrades rather than a Spotify-only partial upgrade."
            ssm_info "Complete your normal pacman/AUR update outside this manager, then return here."
            if [[ -t 0 ]]; then read -r -p "Press Enter after the package update is complete, or Ctrl+C to cancel. " || return 130; else return 69; fi
            ;;
        manual) ssm_info "Update the manual Spotify installation using its original supported method, then return here."
            if [[ -t 0 ]]; then read -r -p "Press Enter after the update is complete, or Ctrl+C to cancel. " || return 130; else return 69; fi
            ;;
        *) return 69 ;;
    esac
}

ssm_save_workflow() {
    ssm_write_state_atomic workflow "schema=$SSM_STATE_SCHEMA" "kind=$SSM_KIND" "scope=$SSM_SCOPE" "owner=manager" "target=$(ssm_control_target)" "phase=$1" "previous=$2" "running=$3" "launch=$4" "path=$SSM_SPOTIFY_PATH"
}

ssm_restore_previous_control() {
    local previous=$1
    case "$previous" in
        blocked-manager|blocked-external) ssm_set_control_raw 1 ;;
        allowed) ssm_set_control_raw 0 ;;
        launcher-blocked)
            ssm_write_state_atomic control "schema=$SSM_STATE_SCHEMA" "kind=launcher" "scope=user" "owner=manager" "target=spotify-launcher" "phase=blocked"
            ;;
        launcher-allowed) ssm_remove_state control ;;
        externally-managed|unavailable) return 0 ;;
        *) ssm_error "Unknown previous update state: $previous"; return 78 ;;
    esac
}

ssm_recover_control_state() {
    local path current query_result
    path=$(ssm_state_path control) || return
    [[ -e "$path" ]] || return 0
    ssm_read_state control || return
    if [[ "$SSM_STATE_OWNER" != manager || "$SSM_STATE_KIND" != "$SSM_KIND" || "$SSM_STATE_SCOPE" != "$SSM_SCOPE" || "$SSM_STATE_TARGET" != "$(ssm_control_target)" ]]; then
        ssm_error "Saved update-control recovery state does not match the detected installation."
        return 78
    fi
    case "$SSM_STATE_PHASE" in
        applying)
            ssm_info "Rolling back an interrupted update-control operation."
            case "$SSM_KIND" in flatpak|apt) ssm_set_control_raw 0 || return;; launcher) :;; *) return 78;; esac
            ssm_remove_state control
            ;;
        blocked)
            current=$(ssm_update_state)
            query_result=$?
            (( query_result == 0 )) || return "$query_result"
            if [[ "$current" == recovery-required ]]; then
                ssm_info "Removing a stale ownership record after the package manager was changed externally."
                ssm_remove_state control
            fi
            ;;
        *) ssm_error "Unknown update-control recovery stage: $SSM_STATE_PHASE"; return 78 ;;
    esac
}

ssm_recover_workflow() {
    local path previous running kind scope spotify_path errors=0
    path=$(ssm_state_path workflow) || return
    if [[ ! -e "$path" ]]; then
        if [[ -e "$(ssm_state_path permissions)" ]]; then
            ssm_info "Recovering interrupted Spotify permission restoration."
            ssm_restore_write_access || return
            ssm_success "Original Spotify resource permissions were restored."
        fi
        ssm_recover_control_state || return
        return 0
    fi
    ssm_read_state workflow || return
    previous=$SSM_STATE_PREVIOUS; running=$SSM_STATE_RUNNING; kind=$SSM_STATE_KIND; scope=$SSM_STATE_SCOPE; spotify_path=$SSM_STATE_PATH
    ssm_info "Recovering interrupted stage: ${SSM_STATE_PHASE:-unknown} (${SSM_STATE_LAUNCH:-unknown launch method})."
    if [[ "$kind" != "$SSM_KIND" || "$scope" != "$SSM_SCOPE" || "$spotify_path" != "$SSM_SPOTIFY_PATH" ]]; then
        ssm_error "Saved recovery state does not match the currently detected Spotify installation."
        return 78
    fi
    if ssm_spotify_running; then ssm_stop_spotify || errors=1; fi
    ssm_restore_previous_control "$previous" || errors=1
    ssm_restore_write_access || errors=1
    if [[ "$running" == 1 ]] && ! ssm_spotify_running; then ssm_start_spotify || errors=1; fi
    if (( errors == 0 )); then
        ssm_remove_state workflow || return
        ssm_success "The interrupted workflow's update and running-state preferences were restored."
    else
        ssm_error "Recovery is incomplete. The recovery state was kept for the next run."
        return 70
    fi
}

ssm_cleanup_temp() {
    if [[ -n "$SSM_TEMP_DIR" && -d "$SSM_TEMP_DIR" ]]; then
        case "$SSM_TEMP_DIR" in
            "${TMPDIR:-/tmp}"/spicetify-manager-*) rm -rf -- "$SSM_TEMP_DIR" ;;
            *) ssm_warn "Refusing to remove unexpected temporary path: $SSM_TEMP_DIR" ;;
        esac
    fi
    SSM_TEMP_DIR=""
}

ssm_signal_handler() {
    local signal=$1 code=$2
    trap - INT TERM HUP
    ssm_warn "Received $signal. Attempting transaction recovery."
    ssm_cleanup_temp
    if (( SSM_WORKFLOW_ACTIVE == 1 )); then ssm_recover_workflow || true; fi
    exit "$code"
}

ssm_guided_update() {
    local previous was_running=0 launch result=0 final query_result
    case "$SSM_SUPPORT" in full|repair-only|launch-control) ;; *) ssm_error "$SSM_CONTEXT_NOTE"; return 69;; esac
    [[ ! -e "$(ssm_state_path workflow)" ]] || { ssm_error "An incomplete workflow already needs recovery."; return 78; }
    previous=$(ssm_update_state)
    query_result=$?
    (( query_result == 0 )) || return "$query_result"
    [[ "$previous" != recovery-required ]] || { ssm_error "Resolve update-control recovery before starting."; return 78; }
    [[ "$SSM_KIND" != launcher ]] || { [[ "$previous" == blocked-manager ]] && previous=launcher-blocked || previous=launcher-allowed; }
    ssm_spotify_running && was_running=1
    launch=$SSM_KIND
    ssm_save_workflow preparing "$previous" "$was_running" "$launch" || return
    SSM_WORKFLOW_ACTIVE=1
    trap 'ssm_signal_handler SIGINT 130' INT
    trap 'ssm_signal_handler SIGTERM 143' TERM
    trap 'ssm_signal_handler SIGHUP 129' HUP
    if (( was_running == 1 )); then
        ssm_confirm "Close Spotify for the guided update?" || { result=64; }
        (( result != 0 )) || ssm_stop_spotify || result=$?
    fi
    if (( result == 0 )); then
        ssm_save_workflow allowing "$previous" "$was_running" "$launch" || result=$?
        case "$previous" in blocked-manager|blocked-external) ssm_set_control_raw 0 || result=$?;; launcher-blocked) ssm_remove_state control || result=$?;; esac
    fi
    if (( result == 0 )); then
        ssm_save_workflow updating "$previous" "$was_running" "$launch" || result=$?
        ssm_package_update || result=$?
    fi
    if (( result == 0 )); then
        ssm_detect_context
        ssm_save_workflow repairing "$previous" "$was_running" "$launch" || result=$?
        if ssm_spicetify_executable >/dev/null; then ssm_repair_spicetify || result=$?; else ssm_warn "Spicetify is not installed, so no repair was run."; fi
    fi
    ssm_save_workflow restoring "$previous" "$was_running" "$launch" || result=$?
    if ssm_spotify_running && ! ssm_stop_spotify; then result=75; fi
    ssm_restore_previous_control "$previous" || result=$?
    ssm_restore_write_access || result=$?
    if (( was_running == 1 )) && ! ssm_spotify_running; then ssm_start_spotify || result=$?; fi
    final=$(ssm_update_state)
    query_result=$?
    (( query_result == 0 )) || result=70
    case "$previous" in
        blocked-manager) [[ "$final" == blocked-manager ]] || result=70 ;;
        blocked-external) [[ "$final" == blocked-external ]] || result=70 ;;
        allowed) [[ "$final" == allowed ]] || result=70 ;;
        launcher-blocked) [[ "$final" == blocked-manager ]] || result=70 ;;
        launcher-allowed) [[ "$final" == allowed ]] || result=70 ;;
    esac
    if (( was_running == 1 )); then ssm_spotify_running || result=75
    else ssm_spotify_running && result=75
    fi
    if (( result == 0 )); then
        ssm_remove_state workflow || result=$?
        SSM_WORKFLOW_ACTIVE=0; trap - INT TERM HUP
        ssm_success "The guided Spotify update and Spicetify check completed, and the final update state was verified."
        return 0
    fi
    ssm_warn "The guided operation failed. Attempting to restore the previous state."
    if ssm_recover_workflow; then
        SSM_WORKFLOW_ACTIVE=0; trap - INT TERM HUP
        ssm_error "The guided operation failed, but its previous state was restored."
    else
        ssm_error "The guided operation failed and recovery still needs attention."
    fi
    return "$result"
}

ssm_recovery_present() {
    local update query_result
    [[ -e "$(ssm_state_path workflow)" || -e "$(ssm_state_path permissions)" ]] && return 0
    update=$(ssm_update_state 2>/dev/null)
    query_result=$?
    (( query_result == 0 )) && [[ "$update" == recovery-required ]]
}

ssm_show_status() {
    (( SSM_CONTEXT_READY == 1 )) || ssm_detect_context
    local running="not running" spicetify state update recovery="none" query_result status_result=0
    if ! ssm_have pgrep; then running="unknown (pgrep missing)"
    elif ssm_spotify_running; then running="running"
    fi
    spicetify=$(ssm_spicetify_version)
    if [[ -n "$SSM_SPOTIFY_PATH" && "$spicetify" != "not installed" ]]; then state=$(ssm_spicetify_state); else state="unknown"; fi
    update=$(ssm_update_state)
    query_result=$?
    if (( query_result != 0 )); then update="unknown (state query failed)"; status_result=3; fi
    ssm_recovery_present && recovery="attention required"
    printf '\n%s %s\n' "$SSM_NAME" "$SSM_VERSION"
    printf '  Distribution:  %s\n' "$SSM_DISTRO"
    printf '  Spotify:       %s\n' "$(ssm_context_label)"
    printf '  Install path:  %s\n' "${SSM_SPOTIFY_PATH:-not available}"
    printf '  Spotify ver.:  %s\n' "$SSM_SPOTIFY_VERSION"
    printf '  Process:       %s\n' "$running"
    printf '  Spicetify:     %s (%s)\n' "$spicetify" "$state"
    printf '  Update control:%s%s\n' " " "$update"
    printf '  Recovery:      %s\n' "$recovery"
    [[ -n "$SSM_CONTEXT_NOTE" ]] && printf '  Note:          %s\n' "$SSM_CONTEXT_NOTE"
    case "$SSM_KIND" in none|ambiguous|snap|nix) return 3;; esac
    [[ "$SSM_SUPPORT" != unsupported ]] || return 3
    return "$status_result"
}

ssm_show_diagnostics() {
    ssm_show_status || true
    printf '\nDiagnostics\n'
    printf '  State dir:     %s\n' "$(ssm_state_directory)"
    printf '  Preferences:   %s\n' "${SSM_PREFS_PATH:-not available}"
    printf '  Bash:          %s\n' "$BASH_VERSION"
    printf '  Commands:      '
    local command
    for command in flatpak dpkg-query apt-mark apt-get pacman spotify-launcher spicetify pgrep sudo curl; do
        ssm_have "$command" && printf '%s ' "$command"
    done
    printf '\n'
}

ssm_print_help() {
    cat <<'EOF'
Usage: Spicetify-Spotify-Manager-Linux.sh [option]

Options:
  --help                    Show this help text.
  --version                 Show the manager version.
  --status                  Print status and return 0 when supported, 3 otherwise.
  --spotify-path PATH       Use a verified manual Spotify resource path.
  --prefs-path PATH         Preferences file for a manual path.

Without an option, the manager opens its interactive menu. Run it as your
normal user. It requests privilege only for an exact APT or permission command.
EOF
}

ssm_show_menu() {
    while true; do
        ssm_detect_context
        ssm_recovery_present && {
            ssm_warn "Managed recovery state exists. Recovery must be resolved before normal actions."
            if ssm_confirm "Attempt safe recovery now?" yes; then ssm_recover_workflow || true; fi
        }
        ssm_show_status || true
        cat <<'EOF'

  1. Guided Spotify update and Spicetify repair
  2. Install or update Spicetify CLI
  3. Reapply or repair Spicetify
  4. Block or control Spotify updates
  5. Allow Spotify updates
  6. Show detailed diagnostics
  7. Exit
EOF
        local choice result=0
        read -r -p "Select an action: " choice || return 0
        case "$choice" in
            1) ssm_guided_update || result=$? ;;
            2) ssm_install_or_update_spicetify || result=$? ;;
            3)
                if ssm_spotify_running; then ssm_confirm "Close Spotify while Spicetify is repaired?" || { result=64; }
                    (( result != 0 )) || ssm_stop_spotify || result=$?
                    if (( result == 0 )); then ssm_repair_spicetify || result=$?; ssm_start_spotify || true; fi
                else ssm_repair_spicetify || result=$?; fi
                ;;
            4) ssm_confirm "Apply the update control described for this installation?" || result=64; (( result != 0 )) || ssm_block_updates || result=$? ;;
            5) ssm_confirm "Remove only update control created by this manager?" || result=64; (( result != 0 )) || ssm_allow_updates || result=$? ;;
            6) ssm_show_diagnostics ;;
            7) return 0 ;;
            *) ssm_warn "Choose a listed menu number."; result=64 ;;
        esac
        (( result == 0 )) || ssm_warn "Action finished with exit code $result."
        printf '\n'; read -r -p "Press Enter to continue. " _ || return 0
    done
}

# <SPICETIFY_MANAGER_LINUX_MAIN>
# shellcheck shell=bash
# Generated entry point. Keep argument parsing here and reusable logic in core.sh.
ssm_main() {
    local action="menu"
    local result
    while (($#)); do
        case "$1" in
            --help|-h) action="help"; shift ;;
            --version|-V) action="version"; shift ;;
            --status) action="status"; shift ;;
            --spotify-path)
                (($# >= 2)) || { ssm_error "--spotify-path requires a value."; return 64; }
                # shellcheck disable=SC2034 # Used by core.sh after generation.
                SSM_MANUAL_SPOTIFY_PATH=$2; shift 2
                ;;
            --prefs-path)
                (($# >= 2)) || { ssm_error "--prefs-path requires a value."; return 64; }
                # shellcheck disable=SC2034 # Used by core.sh after generation.
                SSM_MANUAL_PREFS_PATH=$2; shift 2
                ;;
            --) shift; break ;;
            *) ssm_error "Unknown option: $1"; ssm_print_help >&2; return 64 ;;
        esac
    done
    case "$action" in
        help) ssm_print_help ;;
        version) printf '%s %s\n' "$SSM_NAME" "$SSM_VERSION" ;;
        status)
            ssm_require_non_root
            result=$?
            (( result == 0 )) || return "$result"
            ssm_detect_context
            ssm_show_status
            ;;
        menu)
            ssm_require_non_root
            result=$?
            (( result == 0 )) || return "$result"
            ssm_detect_context
            ssm_show_menu
            ;;
    esac
}

if [[ "${SSM_SOURCE_ONLY:-0}" != "1" ]]; then
    ssm_main "$@"
    exit $?
fi
