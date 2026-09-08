# shellcheck shell=bash
# Generated entry point. Keep argument parsing here and reusable logic in core.sh.
ssm_main() {
    local action="menu"
    local result
    local action_seen=0
    while (($#)); do
        case "$1" in --help|-h|--version|-V|--status)
            (( action_seen == 0 )) || { ssm_error "Choose only one command-line action."; return 64; }
            action_seen=1 ;;
        esac
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
    (( $# == 0 )) || { ssm_error "Unexpected positional arguments."; return 64; }
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
            trap 'ssm_signal_handler SIGINT 130' INT
            trap 'ssm_signal_handler SIGTERM 143' TERM
            trap 'ssm_signal_handler SIGHUP 129' HUP
            ssm_detect_context
            ssm_show_menu
            ;;
    esac
}

if [[ "${SSM_SOURCE_ONLY:-0}" != "1" ]]; then
    ssm_main "$@"
    exit $?
fi
