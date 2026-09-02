#!/usr/bin/env bash
set -uo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly test_dir
repo=$(cd -- "$test_dir/.." && pwd -P)
readonly repo
readonly release="$repo/Spicetify-Spotify-Manager-Linux.sh"
readonly expected_windows_sha="65c8546bfff555a52599fd6d155358e8b14caedf6dc609aa7d704e0253d19599"

passed=0
failed=0
TEST_ASSERT_FAILED=0
temporary_roots=()

pass() { printf 'PASS  %s\n' "$1"; ((passed+=1)); }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2" >&2; ((failed+=1)); }

run_test() {
    local name=$1
    local result
    shift
    if (
        TEST_ASSERT_FAILED=0
        # Each test owns and removes its fixtures inside this isolated subshell.
        # shellcheck disable=SC2030
        temporary_roots=()
        trap cleanup EXIT
        "$@"
        result=$?
        cleanup || result=1
        trap - EXIT
        (( result == 0 && TEST_ASSERT_FAILED == 0 ))
    ); then pass "$name"; else fail "$name" "test or assertion failed"; fi
}

assert_eq() { [[ "$1" == "$2" ]] || { TEST_ASSERT_FAILED=1; printf 'expected <%s>, got <%s>\n' "$2" "$1" >&2; return 1; }; }
assert_contains() { [[ "$1" == *"$2"* ]] || { TEST_ASSERT_FAILED=1; printf 'missing text <%s>\n' "$2" >&2; return 1; }; }
assert_file() { [[ -f "$1" ]] || { TEST_ASSERT_FAILED=1; printf 'missing file <%s>\n' "$1" >&2; return 1; }; }
assert_no_file() { [[ ! -e "$1" ]] || { TEST_ASSERT_FAILED=1; printf 'unexpected file <%s>\n' "$1" >&2; return 1; }; }

new_root() {
    NEW_TEST_ROOT=$(mktemp -d -- "${TMPDIR:-/tmp}/ssm-linux-tests.XXXXXX") || return
    # shellcheck disable=SC2031 # The matching cleanup trap runs in the same test subshell.
    temporary_roots+=("$NEW_TEST_ROOT")
}

make_fake_commands() {
    local root=$1
    local fake="$root/fakebin"
    local dispatcher="$root/fake-dispatch"
    mkdir -p -- "$fake" "$root/fake-state"
    cat > "$dispatcher" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
name=${0##*/}
state=${SSM_FAKE_STATE:?}
case "$name" in
  flatpak)
    command=${1:-}; shift || true
    case "$command" in
      info)
        scope=""; mode=""
        for arg in "$@"; do case "$arg" in --user) scope=user;; --system) scope=system;; --show-location) mode=location;; --show-version) mode=version;; esac; done
        [[ -n "$scope" && "${!scope:-0}" == 1 ]] || exit 1
        case "$mode" in location) [[ "${SSM_FAKE_BAD_LOCATION:-0}" == 1 ]] && printf 'not-an-absolute-path\n' || printf '%s\n' "${state}/flatpak-${scope}/deployment";; version) printf '%s\n' "1.2.99.${scope}";; *) exit 0;; esac
        ;;
      mask)
        scope=system; remove=0; target=""
        for arg in "$@"; do case "$arg" in --user) scope=user;; --system) scope=system;; --remove) remove=1;; *) target=$arg;; esac; done
        file="$state/mask-$scope"
        if [[ -z "$target" ]]; then [[ "${SSM_FAKE_QUERY_FAIL:-0}" != 1 ]] || { printf 'mock mask query failure\n' >&2; exit 9; }; [[ -f "$file" ]] && cat "$file"; exit 0; fi
        if [[ "${SSM_FAKE_MASK_PARTIAL:-0}" == 1 && "$remove" == 0 ]]; then printf '%s\n' "$target" > "$file"; printf 'mock partial mask failure\n' >&2; exit 9; fi
        [[ "${SSM_FAKE_MASK_FAIL:-0}" != 1 ]] || { printf 'mock mask failure\n' >&2; exit 9; }
        if [[ "${SSM_FAKE_MASK_NOOP:-0}" != 1 ]]; then
          if (( remove == 1 )); then rm -f -- "$file"; else printf '%s\n' "$target" > "$file"; fi
        fi
        ;;
      update) [[ "${SSM_FAKE_UPDATE_FAIL:-0}" != 1 ]] || { printf 'mock update failure\n' >&2; exit 8; }; printf '%s\n' "$*" > "$state/flatpak-update";;
      run) printf '%s\n' "$*" > "$state/flatpak-run"; printf '4242\n' > "$state/running";;
      *) exit 2;;
    esac
    ;;
  dpkg-query)
    if [[ "$1" == -W ]]; then [[ "${apt:-0}" == 1 ]] || exit 1; [[ "${SSM_FAKE_BAD_APT:-0}" == 1 ]] && printf 'installed\t1.2.3\nforged\n' || printf 'installed\t1.2.99.apt\n'
    elif [[ "$1" == -L ]]; then [[ "${apt:-0}" == 1 ]] || exit 1; printf '%s\n' "$state/apt/usr/share/spotify/Apps"; else exit 2; fi
    ;;
  apt-mark)
    case "$1" in
      showhold) [[ "${SSM_FAKE_QUERY_FAIL:-0}" != 1 ]] || { printf 'mock hold query failure\n' >&2; exit 9; }; [[ -f "$state/apt-hold" ]] && cat "$state/apt-hold"; exit 0;;
      hold) [[ "${SSM_FAKE_HOLD_FAIL:-0}" != 1 ]] || { printf 'mock hold failure\n' >&2; exit 9; }; printf '%s\n' "$2" > "$state/apt-hold";;
      unhold) rm -f -- "$state/apt-hold";;
    esac
    ;;
  apt-get) [[ "${SSM_FAKE_UPDATE_FAIL:-0}" != 1 ]] || exit 8; printf '%s\n' "$*" > "$state/apt-update";;
  sudo) [[ "$1" == -- ]] && shift; "$@";;
  pacman)
    case "$1:$2" in
      -Q:spotify) [[ "${arch:-0}" == 1 ]] || exit 1; printf 'spotify 1.2.99.arch\n';;
      -Q:spotify-launcher) [[ "${launcher_pkg:-0}" == 1 ]] || exit 1; printf 'spotify-launcher 0.6.3\n';;
      -Ql:spotify) [[ "${arch:-0}" == 1 ]] || exit 1; printf 'spotify %s\n' "$state/arch/opt/spotify/Apps/";;
      -Qo:*) exit 1;;
      *) exit 1;;
    esac
    ;;
  spotify-launcher)
    printf '%s\n' "$*" > "$state/launcher-args"
    [[ "${SSM_FAKE_UPDATE_FAIL:-0}" != 1 ]] || exit 8
    [[ " $* " == *" --no-exec "* ]] || printf '4242\n' > "$state/running"
    ;;
  snap) [[ "${snap:-0}" == 1 && "$1:$2" == list:spotify ]] || exit 1;;
  pgrep) [[ -f "$state/running" ]] && { cat "$state/running"; exit 0; }; exit 1;;
  spicetify)
    case "${1:-}" in
      -v|--version) printf '2.44.0\n';;
      path) [[ "${2:-}" == userdata ]] && printf '%s\n' "$state/spicetify-config" || exit 1;;
      config)
        mkdir -p "$state/spicetify-config"
        cat > "$state/spicetify-config/config-xpui.ini" <<EOF
[Setting]
spotify_path = $3
prefs_path = $5
[Backup]
version = 1.2.99.test
EOF
        ;;
      backup|restore)
        [[ "${SSM_FAKE_SPICETIFY_FAIL:-0}" != 1 ]] || { printf 'mock spicetify failure\n' >&2; exit 7; }
        apps=${SSM_FAKE_SPOTIFY_PATH:?}/Apps
        rm -f "$apps/xpui.spa"; mkdir -p "$apps/xpui"; printf 'applied\n' > "$apps/xpui/xpui.js"
        ;;
      update) exit 0;;
      *) exit 1;;
    esac
    ;;
  curl) printf '#!/usr/bin/env sh\n# github.com/spicetify/cli/releases\n' > "${*: -1}";;
  *) printf 'unknown fake command %s\n' "$name" >&2; exit 127;;
esac
FAKE
    chmod +x "$dispatcher"
    local command
    for command in flatpak dpkg-query apt-mark apt-get sudo pacman snap pgrep spicetify curl; do cp "$dispatcher" "$fake/$command"; done
    printf '%s\n' "$fake"
}

make_spotify_tree() {
    local path=$1
    mkdir -p -- "$path/Apps"
    printf 'stock\n' > "$path/Apps/xpui.spa"
}

setup_case() {
    new_root || return
    CASE_ROOT=$NEW_TEST_ROOT
    export HOME="$CASE_ROOT/Home With Spaces ü"
    export XDG_STATE_HOME="$HOME/.state"
    export XDG_DATA_HOME="$HOME/.local/share"
    mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME"
    export SSM_FAKE_STATE="$CASE_ROOT/fake-state"
    CASE_FAKEBIN=$(make_fake_commands "$CASE_ROOT") || return
    export PATH="$CASE_FAKEBIN:/usr/bin:/bin"
    unset user system apt arch launcher_pkg snap SSM_FAKE_MASK_FAIL SSM_FAKE_MASK_NOOP SSM_FAKE_MASK_PARTIAL SSM_FAKE_BAD_LOCATION SSM_FAKE_BAD_APT SSM_FAKE_HOLD_FAIL SSM_FAKE_QUERY_FAIL SSM_FAKE_UPDATE_FAIL SSM_FAKE_SPICETIFY_FAIL
    export SSM_SOURCE_ONLY=1
    # shellcheck source=/dev/null
    source "$release"
    # shellcheck disable=SC2034 # Read by sourced manager functions.
    SSM_MANUAL_SPOTIFY_PATH=""
    # shellcheck disable=SC2034 # Read by sourced manager functions.
    SSM_MANUAL_PREFS_PATH=""
    # shellcheck disable=SC2034 # Read by sourced manager functions.
    SSM_CONTEXT_READY=0
}

test_bash_syntax() { bash -n "$release"; }
test_lf() { ! LC_ALL=C grep -q $'\r' "$release"; }
test_executable() { [[ -x "$release" ]]; }
test_marker() { [[ "$(grep -Fxc '# <SPICETIFY_MANAGER_LINUX_MAIN>' "$release")" == 1 ]]; }
test_no_local_paths() { ! grep -Eq 'C:\\Users\\|/home/runner/' "$release"; }
test_windows_hash() { assert_eq "$(sha256sum "$repo/Spicetify-Spotify-Manager.bat" | cut -d' ' -f1)" "$expected_windows_sha"; }
test_deterministic() { "$repo/build/build-linux-release.sh" --check >/dev/null; local a b; a=$(sha256sum "$release"); "$repo/build/build-linux-release.sh" >/dev/null; b=$(sha256sum "$release"); assert_eq "$a" "$b"; }
test_help() { assert_contains "$("$release" --help)" '--status'; }
test_version() { assert_eq "$("$release" --version)" 'Spicetify Spotify Manager 1.1.0'; }
test_unknown_option() { "$release" --not-real >/dev/null 2>&1; [[ $? == 64 ]]; }

test_root_refusal() { setup_case; # shellcheck disable=SC2329
    ssm_current_uid(){ printf '0\n'; }; ssm_require_non_root >/dev/null 2>&1; [[ $? == 77 ]]; }
test_state_atomic() { setup_case; ssm_write_state_atomic control 'schema=1' 'kind=launcher' 'scope=user' 'owner=manager' 'target=spotify-launcher' 'phase=blocked'; ssm_validate_state_file "$(ssm_state_path control)"; [[ "$(stat -c %a "$(ssm_state_path control)")" == 600 ]]; ! find "$XDG_STATE_HOME" -name '*.tmp.*' | grep -q .; }
test_state_corruption() { setup_case; mkdir -p "$(ssm_state_directory)"; chmod 700 "$(ssm_state_directory)"; printf 'bad\n' > "$(ssm_state_path control)"; chmod 600 "$(ssm_state_path control)"; ssm_read_state control >/dev/null 2>&1; [[ $? == 78 ]]; }
test_unsafe_state_mode() { setup_case; mkdir -p "$(ssm_state_directory)"; chmod 700 "$(ssm_state_directory)"; printf 'schema\t1\n' > "$(ssm_state_path control)"; chmod 666 "$(ssm_state_path control)"; ssm_read_state control >/dev/null 2>&1; [[ $? == 78 ]]; }
test_symlink_state() { setup_case; mkdir -p "$(ssm_state_directory)"; chmod 700 "$(ssm_state_directory)"; touch "$CASE_ROOT/outside"; ln -s "$CASE_ROOT/outside" "$(ssm_state_path control)"; ssm_read_state control >/dev/null 2>&1; [[ $? == 78 ]]; }

setup_flatpak() {
    setup_case
    export user=1
    make_spotify_tree "$SSM_FAKE_STATE/flatpak-user/deployment/files/extra/share/spotify"
    mkdir -p "$HOME/.var/app/com.spotify.Client/config/spotify"
    printf 'app.last-launched-version="1.2.99.test"\n' > "$HOME/.var/app/com.spotify.Client/config/spotify/prefs"
    ssm_detect_context
}
test_flatpak_user() { setup_flatpak; assert_eq "$SSM_KIND:$SSM_SCOPE" 'flatpak:user'; assert_eq "$SSM_SUPPORT" full; }
test_flatpak_system() { setup_case; export system=1; make_spotify_tree "$SSM_FAKE_STATE/flatpak-system/deployment/files/extra/share/spotify"; ssm_detect_context; assert_eq "$SSM_KIND:$SSM_SCOPE" 'flatpak:system'; }
test_flatpak_ambiguous() { setup_case; export user=1 system=1; make_spotify_tree "$SSM_FAKE_STATE/flatpak-user/deployment/files/extra/share/spotify"; make_spotify_tree "$SSM_FAKE_STATE/flatpak-system/deployment/files/extra/share/spotify"; ssm_detect_context; assert_eq "$SSM_KIND" ambiguous; }
test_flatpak_external_mask() { setup_flatpak; printf 'com.spotify.Client\n' > "$SSM_FAKE_STATE/mask-user"; assert_eq "$(ssm_update_state)" blocked-external; ssm_block_updates >/dev/null; assert_no_file "$(ssm_state_path control)"; ssm_allow_updates >/dev/null 2>&1; assert_file "$SSM_FAKE_STATE/mask-user"; }
test_flatpak_owned_cycle() { setup_flatpak; ssm_block_updates >/dev/null; assert_eq "$(ssm_update_state)" blocked-manager; ssm_block_updates >/dev/null; ssm_allow_updates >/dev/null; assert_eq "$(ssm_update_state)" allowed; ssm_allow_updates >/dev/null; }
test_flatpak_failure() { setup_flatpak; export SSM_FAKE_MASK_FAIL=1; ssm_block_updates >/dev/null 2>&1; [[ $? == 70 ]] || return; assert_no_file "$(ssm_state_path control)"; assert_eq "$(ssm_update_state)" allowed; }
test_flatpak_partial_failure() { setup_flatpak; export SSM_FAKE_MASK_PARTIAL=1; local output result; output=$(ssm_block_updates 2>&1); result=$?; assert_eq "$result" 70; assert_contains "$output" 'mock partial mask failure'; assert_no_file "$SSM_FAKE_STATE/mask-user"; assert_no_file "$(ssm_state_path control)"; assert_eq "$(ssm_update_state)" allowed; }
test_flatpak_query_failure() { setup_flatpak; export SSM_FAKE_QUERY_FAIL=1; local output result; output=$(ssm_block_updates 2>&1); result=$?; assert_eq "$result" 70; assert_contains "$output" 'mock mask query failure'; assert_no_file "$(ssm_state_path control)"; }
test_flatpak_final_verification() { setup_flatpak; export SSM_FAKE_MASK_NOOP=1; ssm_block_updates >/dev/null 2>&1; [[ $? == 70 ]] && assert_no_file "$(ssm_state_path control)"; }
test_flatpak_bad_metadata() { setup_case; export user=1 SSM_FAKE_BAD_LOCATION=1; ssm_detect_context; assert_eq "$SSM_KIND" flatpak; assert_eq "$SSM_SUPPORT" unsupported; }
test_flatpak_missing_resources() { setup_case; export user=1; ssm_detect_context; assert_eq "$SSM_SUPPORT" unsupported; }
test_flatpak_relaunch() { setup_flatpak; ssm_start_spotify; assert_file "$SSM_FAKE_STATE/flatpak-run"; ssm_spotify_running; }

setup_apt() {
    setup_case; export apt=1
    make_spotify_tree "$SSM_FAKE_STATE/apt/usr/share/spotify"
    mkdir -p "$HOME/.config/spotify"; printf 'app.last-launched-version="1.2.99.test"\n' > "$HOME/.config/spotify/prefs"
    ssm_detect_context
}
test_apt_detection() { setup_apt; assert_eq "$SSM_KIND:$SSM_SCOPE" 'apt:system'; assert_eq "$SSM_SPOTIFY_VERSION" '1.2.99.apt'; }
test_apt_external_hold() { setup_apt; printf 'spotify-client\n' > "$SSM_FAKE_STATE/apt-hold"; assert_eq "$(ssm_update_state)" blocked-external; ssm_allow_updates >/dev/null 2>&1; assert_file "$SSM_FAKE_STATE/apt-hold"; }
test_apt_owned_cycle() { setup_apt; ssm_block_updates >/dev/null; ssm_block_updates >/dev/null; assert_file "$SSM_FAKE_STATE/apt-hold"; ssm_allow_updates >/dev/null; ssm_allow_updates >/dev/null; assert_no_file "$SSM_FAKE_STATE/apt-hold"; }
test_apt_failure_recovery() { setup_apt; export SSM_FAKE_HOLD_FAIL=1; ssm_block_updates >/dev/null 2>&1; [[ $? == 70 ]] && assert_no_file "$(ssm_state_path control)"; }
test_apt_query_failure() { setup_apt; export SSM_FAKE_QUERY_FAIL=1; local output result; output=$(ssm_allow_updates 2>&1); result=$?; assert_eq "$result" 70; assert_contains "$output" 'mock hold query failure'; assert_no_file "$(ssm_state_path control)"; }
test_apt_bad_metadata() { setup_case; export apt=1 SSM_FAKE_BAD_APT=1; make_spotify_tree "$SSM_FAKE_STATE/apt/usr/share/spotify"; ssm_detect_context; assert_eq "$SSM_KIND" none; }
test_apt_guided_exact_package() { setup_apt; export SSM_FAKE_SPOTIFY_PATH=$SSM_SPOTIFY_PATH; ssm_guided_update >/dev/null; assert_contains "$(cat "$SSM_FAKE_STATE/apt-update")" '--only-upgrade -- spotify-client'; assert_eq "$(ssm_update_state)" allowed; }

test_arch_detection() { setup_case; export arch=1; make_spotify_tree "$SSM_FAKE_STATE/arch/opt/spotify"; ssm_detect_context; assert_eq "$SSM_KIND" arch; assert_eq "$(ssm_update_state)" externally-managed; }
test_launcher_detection() { setup_case; cp "$CASE_ROOT/fake-dispatch" "$CASE_FAKEBIN/spotify-launcher"; make_spotify_tree "$XDG_DATA_HOME/spotify-launcher/install/usr/share/spotify"; ssm_detect_context; assert_eq "$SSM_KIND" launcher; ssm_block_updates >/dev/null; assert_eq "$(ssm_update_state)" blocked-manager; }
test_launcher_scope() { setup_case; cp "$CASE_ROOT/fake-dispatch" "$CASE_FAKEBIN/spotify-launcher"; make_spotify_tree "$XDG_DATA_HOME/spotify-launcher/install/usr/share/spotify"; ssm_detect_context; ssm_block_updates >/dev/null; ssm_start_spotify; sleep 0.1; assert_contains "$(cat "$SSM_FAKE_STATE/launcher-args")" '--skip-update'; }
test_snap_rejection() { setup_case; export snap=1; ssm_detect_context; assert_eq "$SSM_KIND" snap; [[ "$SSM_CONTEXT_NOTE" == *unsupported* ]]; }
test_nix_guidance() { setup_case; # shellcheck disable=SC2329
    ssm_nix_detected(){ return 0; }; ssm_detect_context; assert_eq "$SSM_KIND" nix; assert_contains "$SSM_CONTEXT_NOTE" spicetify-nix; }
test_unknown_rejection() { setup_case; ssm_detect_context; assert_eq "$SSM_KIND" none; ssm_show_status >/dev/null; [[ $? == 3 ]]; }
test_missing_dependency() { setup_case; ssm_require_command definitely-not-installed >/dev/null 2>&1; [[ $? == 69 ]]; }
test_status_from_other_directory() { setup_flatpak; local output; output=$(cd /tmp && env -u SSM_SOURCE_ONLY "$release" --status); assert_contains "$output" 'Flatpak (user)'; assert_contains "$output" "$SSM_SPOTIFY_PATH"; }

test_manual_path() { setup_case; local path="$CASE_ROOT/Manual Spotify ü"; make_spotify_tree "$path"; SSM_MANUAL_SPOTIFY_PATH=$path; ssm_detect_context; assert_eq "$SSM_KIND" manual; assert_eq "$SSM_SPOTIFY_PATH" "$path"; }
test_manual_missing_resources() { setup_case; local path="$CASE_ROOT/not spotify"; mkdir -p "$path"; SSM_MANUAL_SPOTIFY_PATH=$path; ssm_detect_context; assert_eq "$SSM_SUPPORT" unsupported; }
test_manual_symlink_rejection() { setup_case; local real="$CASE_ROOT/real" link="$CASE_ROOT/link"; make_spotify_tree "$real"; ln -s "$real" "$link"; SSM_MANUAL_SPOTIFY_PATH=$link; ssm_detect_context; assert_eq "$SSM_SUPPORT" unsupported; }
test_manual_injection_text() { setup_case; local path="$CASE_ROOT/Spotify ; touch PWNED"; make_spotify_tree "$path"; # shellcheck disable=SC2034
    SSM_MANUAL_SPOTIFY_PATH=$path; ssm_detect_context; assert_eq "$SSM_SPOTIFY_PATH" "$path"; assert_no_file "$CASE_ROOT/PWNED"; }

test_process_states() { setup_case; if ssm_spotify_running; then return 1; fi; printf '4242\n' > "$SSM_FAKE_STATE/running"; ssm_spotify_running; assert_eq "$(ssm_spotify_pids)" 4242; }
test_spicetify_missing() { setup_case; rm "$CASE_FAKEBIN/spicetify"; assert_eq "$(ssm_spicetify_version)" 'not installed'; }
test_spicetify_unapplied() { setup_flatpak; assert_eq "$(ssm_spicetify_state)" unapplied; }
test_spicetify_apply() { setup_flatpak; export SSM_FAKE_SPOTIFY_PATH=$SSM_SPOTIFY_PATH; ssm_repair_spicetify >/dev/null; assert_eq "$(ssm_spicetify_state)" applied; }
test_spicetify_failure() { setup_flatpak; export SSM_FAKE_SPOTIFY_PATH=$SSM_SPOTIFY_PATH SSM_FAKE_SPICETIFY_FAIL=1; ssm_repair_spicetify >/dev/null 2>&1; [[ $? == 70 ]]; }
test_spicetify_stale() { setup_flatpak; export SSM_FAKE_SPOTIFY_PATH=$SSM_SPOTIFY_PATH; ssm_repair_spicetify >/dev/null; printf 'app.last-launched-version="different"\n' > "$SSM_PREFS_PATH"; assert_eq "$(ssm_spicetify_state)" stale; }

test_guided_flatpak_success() { setup_flatpak; export SSM_FAKE_SPOTIFY_PATH=$SSM_SPOTIFY_PATH; ssm_block_updates >/dev/null; ssm_guided_update >/dev/null; assert_eq "$(ssm_update_state)" blocked-manager; assert_file "$SSM_FAKE_STATE/flatpak-update"; assert_no_file "$(ssm_state_path workflow)"; }
test_guided_failure_rollback() { setup_flatpak; export SSM_FAKE_SPOTIFY_PATH=$SSM_SPOTIFY_PATH SSM_FAKE_UPDATE_FAIL=1; ssm_block_updates >/dev/null; if ssm_guided_update >/dev/null 2>&1; then return 1; fi; assert_eq "$(ssm_update_state)" blocked-manager; assert_no_file "$(ssm_state_path workflow)"; }
test_recovery_state() { setup_flatpak; ssm_save_workflow interrupted allowed 0 flatpak; ssm_recovery_present; ssm_recover_workflow >/dev/null; assert_no_file "$(ssm_state_path workflow)"; }
test_control_only_recovery() { setup_flatpak; ssm_write_state_atomic control 'schema=1' 'kind=flatpak' 'scope=user' 'owner=manager' 'target=com.spotify.Client' 'phase=applying'; assert_eq "$(ssm_update_state)" recovery-required; ssm_recover_workflow >/dev/null; assert_eq "$(ssm_update_state)" allowed; assert_no_file "$(ssm_state_path control)"; }
test_permission_restore() { setup_apt; local unrelated="$CASE_ROOT/unrelated"; printf 'keep\n' > "$unrelated"; chmod 640 "$unrelated"; ln -s "$unrelated" "$SSM_SPOTIFY_PATH/Apps/unrelated-link"; chmod 555 "$SSM_SPOTIFY_PATH" "$SSM_SPOTIFY_PATH/Apps"; chmod 444 "$SSM_SPOTIFY_PATH/Apps/xpui.spa"; local root_before apps_before file_before unrelated_before; root_before=$(stat -c %a "$SSM_SPOTIFY_PATH"); apps_before=$(stat -c %a "$SSM_SPOTIFY_PATH/Apps"); file_before=$(stat -c %a "$SSM_SPOTIFY_PATH/Apps/xpui.spa"); unrelated_before=$(stat -c %a "$unrelated"); # shellcheck disable=SC2329
    ssm_confirm(){ return 0; }; ssm_prepare_write_access; assert_file "$(ssm_state_path permissions)"; [[ -w "$SSM_SPOTIFY_PATH/Apps/xpui.spa" ]]; ssm_restore_write_access; assert_eq "$(stat -c %a "$SSM_SPOTIFY_PATH")" "$root_before"; assert_eq "$(stat -c %a "$SSM_SPOTIFY_PATH/Apps")" "$apps_before"; assert_eq "$(stat -c %a "$SSM_SPOTIFY_PATH/Apps/xpui.spa")" "$file_before"; assert_eq "$(stat -c %a "$unrelated")" "$unrelated_before"; assert_eq "$(cat "$unrelated")" keep; assert_no_file "$(ssm_state_path permissions)"; }
test_permission_failure_recovery() { setup_apt; chmod 555 "$SSM_SPOTIFY_PATH" "$SSM_SPOTIFY_PATH/Apps"; chmod 444 "$SSM_SPOTIFY_PATH/Apps/xpui.spa"; local calls=0; # shellcheck disable=SC2329
    ssm_confirm(){ return 0; }; # shellcheck disable=SC2329
    ssm_run_privileged(){ ((calls+=1)); (( calls != 2 )) || return 1; "$@"; }
    if ssm_prepare_write_access >/dev/null 2>&1; then return 1; fi; assert_file "$(ssm_state_path permissions)"; # shellcheck disable=SC2329
    ssm_run_privileged(){ "$@"; }; ssm_recover_workflow >/dev/null; assert_eq "$(stat -c %a "$SSM_SPOTIFY_PATH")" 555; assert_eq "$(stat -c %a "$SSM_SPOTIFY_PATH/Apps")" 555; assert_eq "$(stat -c %a "$SSM_SPOTIFY_PATH/Apps/xpui.spa")" 444; assert_no_file "$(ssm_state_path permissions)"; }
test_permission_restore_verification() { setup_apt; chmod 555 "$SSM_SPOTIFY_PATH" "$SSM_SPOTIFY_PATH/Apps"; chmod 444 "$SSM_SPOTIFY_PATH/Apps/xpui.spa"; # shellcheck disable=SC2329
    ssm_confirm(){ return 0; }; ssm_prepare_write_access; # shellcheck disable=SC2329
    ssm_run_privileged(){ return 0; }; if ssm_restore_write_access >/dev/null 2>&1; then return 1; fi; assert_file "$(ssm_state_path permissions)"; }

test_sigint_cleanup() { setup_case; local temp code; temp=$(mktemp -d /tmp/spicetify-manager-signal.XXXXXX); ( # shellcheck disable=SC2034
    SSM_TEMP_DIR=$temp; trap 'ssm_signal_handler SIGINT 130' INT; kill -INT "$BASHPID"; exit 99) >/dev/null 2>&1; code=$?; assert_eq "$code" 130; assert_no_file "$temp"; }
test_sighup_cleanup() { setup_case; local temp code; temp=$(mktemp -d /tmp/spicetify-manager-signal.XXXXXX); ( # shellcheck disable=SC2034
    SSM_TEMP_DIR=$temp; trap 'ssm_signal_handler SIGHUP 129' HUP; kill -HUP "$BASHPID"; exit 99) >/dev/null 2>&1; code=$?; assert_eq "$code" 129; assert_no_file "$temp"; }
test_sigterm_rollback() { setup_flatpak; local code; printf 'com.spotify.Client\n' > "$SSM_FAKE_STATE/mask-user"; ssm_save_workflow updating allowed 0 flatpak; ( # shellcheck disable=SC2034
    SSM_WORKFLOW_ACTIVE=1; trap 'ssm_signal_handler SIGTERM 143' TERM; kill -TERM "$BASHPID"; exit 99) >/dev/null 2>&1; code=$?; assert_eq "$code" 143; assert_no_file "$SSM_FAKE_STATE/mask-user"; assert_no_file "$(ssm_state_path workflow)"; }

cleanup() {
    local root
    for root in "${temporary_roots[@]}"; do
        [[ "$root" == "${TMPDIR:-/tmp}/ssm-linux-tests."* ]] || { printf 'Refusing unsafe test cleanup: %s\n' "$root" >&2; continue; }
        chmod -R u+rwX -- "$root" 2>/dev/null || true
        rm -rf -- "$root"
        [[ ! -e "$root" ]] || return 1
    done
}
trap cleanup EXIT

run_test 'Bash syntax is valid' test_bash_syntax
run_test 'Linux artifact uses LF endings' test_lf
run_test 'Linux artifact is executable' test_executable
run_test 'generated marker is resolved exactly once' test_marker
run_test 'generated artifact has no local-machine paths' test_no_local_paths
run_test 'Windows release hash is unchanged' test_windows_hash
run_test 'Linux generation is deterministic' test_deterministic
run_test '--help works' test_help
run_test '--version works' test_version
run_test 'unknown options use an informative exit code' test_unknown_option
run_test 'normal operation refuses root' test_root_refusal
run_test 'state writes are atomic and private' test_state_atomic
run_test 'corrupt state is rejected' test_state_corruption
run_test 'unsafe state permissions are rejected' test_unsafe_state_mode
run_test 'symlink state files are rejected' test_symlink_state
run_test 'Flatpak user install is detected' test_flatpak_user
run_test 'Flatpak system install is detected' test_flatpak_system
run_test 'dual-scope Flatpak is ambiguous' test_flatpak_ambiguous
run_test 'external Flatpak mask is preserved' test_flatpak_external_mask
run_test 'manager Flatpak mask is idempotent' test_flatpak_owned_cycle
run_test 'Flatpak mask failures do not claim ownership' test_flatpak_failure
run_test 'partial Flatpak mask failures roll back immediately' test_flatpak_partial_failure
run_test 'Flatpak mask-query failures never report allowed' test_flatpak_query_failure
run_test 'Flatpak changes require final-state verification' test_flatpak_final_verification
run_test 'malformed Flatpak metadata is rejected' test_flatpak_bad_metadata
run_test 'missing Flatpak resources are rejected' test_flatpak_missing_resources
run_test 'Flatpak relaunch uses the exact application ID' test_flatpak_relaunch
run_test 'APT package is detected from dpkg' test_apt_detection
run_test 'external APT hold is preserved' test_apt_external_hold
run_test 'manager APT hold is idempotent' test_apt_owned_cycle
run_test 'APT hold failure cleans pending ownership' test_apt_failure_recovery
run_test 'APT hold-query failures never report allowed' test_apt_query_failure
run_test 'malformed APT metadata is rejected' test_apt_bad_metadata
run_test 'guided APT update targets only spotify-client' test_apt_guided_exact_package
run_test 'Arch package reports external update management' test_arch_detection
run_test 'spotify-launcher is detected separately' test_launcher_detection
run_test 'launcher blocking is scoped to manager launches' test_launcher_scope
run_test 'Snap is rejected honestly' test_snap_rejection
run_test 'Nix installations receive spicetify-nix guidance' test_nix_guidance
run_test 'unknown installation is rejected' test_unknown_rejection
run_test 'missing dependencies return a useful code' test_missing_dependency
run_test '--status works outside the repository directory' test_status_from_other_directory
run_test 'manual paths with spaces and Unicode work' test_manual_path
run_test 'manual path requires Spotify resources' test_manual_missing_resources
run_test 'manual path symlinks are rejected' test_manual_symlink_rejection
run_test 'manual paths are not evaluated as commands' test_manual_injection_text
run_test 'Spotify process matching is exact' test_process_states
run_test 'missing Spicetify is reported' test_spicetify_missing
run_test 'unapplied Spicetify state is detected' test_spicetify_unapplied
run_test 'Spicetify apply reaches verified state' test_spicetify_apply
run_test 'failed Spicetify commands are returned' test_spicetify_failure
run_test 'stale Spicetify backup is detected' test_spicetify_stale
run_test 'guided Flatpak update restores blocked state' test_guided_flatpak_success
run_test 'guided failure rolls back update control' test_guided_failure_rollback
run_test 'interrupted workflow state is recoverable' test_recovery_state
run_test 'control-only interruption is recoverable' test_control_only_recovery
run_test 'temporary Spotify modes are restored' test_permission_restore
run_test 'permission-command failure remains recoverable' test_permission_failure_recovery
run_test 'permission restoration requires verified final modes' test_permission_restore_verification
run_test 'SIGINT uses code 130 and cleans temporary files' test_sigint_cleanup
run_test 'SIGHUP uses code 129 and cleans temporary files' test_sighup_cleanup
run_test 'SIGTERM uses code 143 and rolls back workflow state' test_sigterm_rollback

printf '\nLinux tests: %d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
