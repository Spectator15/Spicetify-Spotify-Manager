#!/usr/bin/env bash
set -euo pipefail

readonly marker='# <SPICETIFY_MANAGER_LINUX_MAIN>'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_dir
repository_root=$(cd -- "$script_dir/.." && pwd -P)
readonly repository_root
readonly core="$repository_root/src/linux/core.sh"
readonly main="$repository_root/src/linux/main.sh"
readonly version_file="$repository_root/VERSION"
readonly output="$repository_root/Spicetify-Spotify-Manager-Linux.sh"
readonly version_marker='__SPICETIFY_MANAGER_VERSION__'

mode=build
[[ "${1:-}" == "--check" ]] && mode=check
[[ $# == 0 || ( $# == 1 && "$1" == --check ) ]] || { printf 'Usage: %s [--check]\n' "$0" >&2; exit 64; }

for input in "$core" "$main" "$version_file"; do
    [[ -f "$input" ]] || { printf 'Missing build input: %s\n' "$input" >&2; exit 1; }
    if grep -Fq "$marker" "$input"; then
        printf 'Reserved build marker found in input: %s\n' "$input" >&2
        exit 1
    fi
    if LC_ALL=C grep -q $'\r' "$input"; then
        printf 'CR character found in Linux input: %s\n' "$input" >&2
        exit 1
    fi
done

version=$(< "$version_file")
readonly version
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'VERSION must contain a semantic version such as 1.2.3.\n' >&2
    exit 1
}
[[ "$(grep -Foc "$version_marker" "$core")" == 1 ]] || {
    printf 'The Linux source must contain the version marker exactly once.\n' >&2
    exit 1
}

temporary=$(mktemp -- "${TMPDIR:-/tmp}/spicetify-manager-linux.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
{
    sed -e "s/$version_marker/$version/" -e '${/^[[:space:]]*$/d;}' "$core"
    printf '\n%s\n' "$marker"
    sed '1{/^[[:space:]]*$/d;}' "$main"
} > "$temporary"

[[ "$(head -n 1 "$temporary")" == '#!/usr/bin/env bash' ]] || { printf 'Generated file has no Bash shebang.\n' >&2; exit 1; }
[[ "$(grep -Fxc "$marker" "$temporary")" == 1 ]] || { printf 'Generated marker count is invalid.\n' >&2; exit 1; }
! grep -Fq "$version_marker" "$temporary" || { printf 'Generated Linux release contains an unresolved version marker.\n' >&2; exit 1; }
if grep -Eq 'C:\\Users\\|/home/(runner|[^/[:space:]]+)/[^$]' "$temporary"; then
    printf 'Generated file contains a likely local-machine path.\n' >&2
    exit 1
fi
bash -n "$temporary"

if [[ "$mode" == check ]]; then
    [[ -f "$output" ]] || { printf 'Generated Linux release is missing.\n' >&2; exit 1; }
    cmp -s "$temporary" "$output" || { printf 'Generated Linux release is out of date. Run build/build-linux-release.sh.\n' >&2; exit 1; }
    [[ -x "$output" ]] || { printf 'Generated Linux release is not executable.\n' >&2; exit 1; }
    printf 'Generated Linux release is current and deterministic.\n'
else
    install -m 0755 "$temporary" "$output"
    printf 'Generated %s\n' "$output"
fi
