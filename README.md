<h1 align="center">Spicetify Spotify Manager</h1>

<p align="center">A simple menu tool for Windows and Linux that keeps Spicetify working and lets you choose when Spotify updates.</p>

<p align="center">
  <a href="https://github.com/Spectator15/Spicetify-Spotify-Manager/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Spectator15/Spicetify-Spotify-Manager?label=release"></a>
  <a href="https://github.com/Spectator15/Spicetify-Spotify-Manager/actions/workflows/test.yml"><img alt="Tests" src="https://img.shields.io/github/actions/workflow/status/Spectator15/Spicetify-Spotify-Manager/test.yml?branch=main&label=tests"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/github/license/Spectator15/Spicetify-Spotify-Manager"></a>
  <img alt="Platforms: Windows | Linux" src="https://img.shields.io/badge/platforms-Windows%20%7C%20Linux-informational">
  <a href="CHANGELOG.md"><img alt="Next: 1.2.0 in testing" src="https://img.shields.io/badge/next-1.2.0%20in%20testing-orange"></a>
</p>

---

## Quick start

Grab the one file for your system from the [latest release](https://github.com/Spectator15/Spicetify-Spotify-Manager/releases/latest). Nothing else is needed.

**Windows** (standalone Spotify from spotify.com)

Download [`Spicetify-Spotify-Manager.bat`](https://github.com/Spectator15/Spicetify-Spotify-Manager/releases/latest/download/Spicetify-Spotify-Manager.bat) and double-click it.

**Linux**

```bash
chmod +x Spicetify-Spotify-Manager-Linux.sh
./Spicetify-Spotify-Manager-Linux.sh
```

> [!WARNING]
> Run it as your normal user. Do **not** use "Run as administrator" or `sudo`. The manager asks for extra permission only for the single step that needs it, and the Linux version refuses to run as root.

> [!NOTE]
> Version 1.2.0 is in this repo but not released yet. It replaces the Windows `.bat` with a single `Spicetify-Spotify-Manager.exe`. Until it ships, the links above give you 1.1.0.

## Why this exists

I use [Spicetify](https://github.com/spicetify/cli) with the Spotify desktop app. Every time Spotify updated itself, Spicetify broke and I had to fix it by hand. So I made this to control *when* Spotify updates and to turn the fix-up into one menu choice.

It's only about Spotify and Spicetify maintenance. It doesn't patch Spotify, block ads, unlock features, or touch your account.

## Menu options

| Option | What it does |
| --- | --- |
| **Guided Spotify update and Spicetify repair** | Briefly allows an update, updates only Spotify, reapplies Spicetify if needed, then puts your settings back. |
| **Install or update Spicetify CLI** | Uses the official installer, or your package manager if that's how Spicetify was installed. |
| **Reapply or repair Spicetify** | Closes Spotify only if needed, runs `backup apply`, checks the result, and reopens Spotify if it was open. |
| **Block Spotify updates** | Turns on update blocking using the platform's own mechanism. *(Linux: "Block or control Spotify updates")* |
| **Allow Spotify updates** | Removes only blocks this manager created. Blocks you made yourself stay put. |
| **Refresh status / Show detailed diagnostics** | Windows refreshes the status screen. Linux shows paths, package type, versions and state. Neither changes anything. |
| **Restore saved ACL (recovery)** | Windows only. Appears only if a previous run was interrupted. Linux offers recovery automatically at startup. |

## What it does

- Shows Spotify, Spicetify and update-block status every time it opens.
- Blocks updates the proper way for each system: folder permissions on Windows, Flatpak masks or APT holds on Linux.
- Only undoes changes it made itself.
- Saves recovery info before each change, so an interrupted run can be finished next time.
- Never deletes your Spotify data, logins, playlists, Spicetify settings, themes, extensions or Marketplace.
- No telemetry and no access to your Spotify account or passwords.

<details>
<summary><b>Requirements and command-line options</b></summary>

**Windows 1.2.0:** Windows 10/11 with .NET Framework 4.8 and Windows PowerShell 5.1 (both built in). The Microsoft Store version of Spotify is detected but never changed.

**Linux:** Bash, GNU coreutils, `find`, `stat`, `realpath`, `pgrep`, and your Spotify's package manager. `curl` is only needed to download the Spicetify installer. `sudo` is only needed for APT or system Flatpak permission steps.

Read-only options. They never open the menu or change anything:

```text
--help, -h        Show help
--version, -V     Show version (-V is Linux only)
--status          Print status and exit
```

Linux also accepts `--spotify-path PATH` and `--prefs-path PATH` for a manual install. The path must be absolute, contain Spotify's `Apps` folder, and contain no symlink escape. Manual paths never get update blocking.

The Windows options are new in 1.2.0.

| Exit code | Meaning |
| --- | --- |
| `0` | Supported Spotify found |
| `3` | Spotify missing, unsupported or ambiguous (Windows: also Store-only) |
| `64` | Bad arguments |
| `69` | Missing requirement (Linux) |
| `70` | Operation failed |
| `77` | Permission problem, e.g. run as root (Linux) |
| `78` | Unsafe or corrupt saved state (Linux) |

</details>

<details>
<summary><b>Linux package support</b></summary>

> [!TIP]
> On CachyOS, Flatpak Spotify works best with this manager. It has clear user/system scopes, an app-specific update command and a proper mask feature.

| Spotify install | Spicetify | Update blocking | Guided update |
| --- | --- | --- | --- |
| **Flatpak (user)** | Supported | Masks `com.spotify.Client` (user) | Updates only `com.spotify.Client` |
| **Flatpak (system)** | Supported, with temporary scoped permissions | Masks `com.spotify.Client` (system) | Updates only `com.spotify.Client` |
| **APT `spotify-client`** | Supported (verified via `dpkg`) | `apt-mark hold` / `unhold` | `apt-get install --only-upgrade -- spotify-client` |
| **Arch / CachyOS / AUR** | Detect and repair | Managed by your system | Waits for your normal full system update. Never does a partial upgrade. |
| **`spotify-launcher`** | Detect, launch and repair | `--skip-update`, only for launches from this manager | `spotify-launcher --check-update --no-exec` |
| **Manual path** | Status and repair only | Not available | Left to the original installer |
| **Snap** | Not supported | — | Refused (Snap files can't be modified) |
| **Nix / NixOS** | Use [`spicetify-nix`](https://github.com/Gerg-L/spicetify-nix) | Declarative | Not touched |

- If it finds more than one Spotify (e.g. user and system Flatpak), it reports that and refuses to guess.
- `--skip-update` doesn't cover launches from other shortcuts. The manager doesn't edit desktop files or launcher config.
- Broad Flatpak masks that happen to match Spotify are left to you. The manager won't control or remove them.

</details>

<details>
<summary><b>How the guided update works</b></summary>

1. Records the package type, current update block, whether Spotify was running, and the current step.
2. Closes Spotify if it's running and lifts the block where needed.
3. Updates only Spotify, or asks you to run your normal Arch/AUR update and confirm when done.
4. Sets Spicetify's paths and reapplies it only if needed.
5. Restores your previous update-block setting.
6. Reopens Spotify only if it was open before.

It checks real process state instead of waiting a fixed time. If it can't confirm an outside update finished, it asks you. Spicetify is repaired with the official commands:

```bash
spicetify backup apply --no-restart
spicetify restore backup apply --no-restart
```

If Spotify is newer than Spicetify supports, Spicetify may refuse. The manager shows that error and doesn't report success.

</details>

<details>
<summary><b>Windows update blocking (safety details)</b></summary>

- Only ever touches `%LOCALAPPDATA%\Spotify\Update`. Any other path, or a junction or reparse point anywhere along it, is refused before anything changes.
- Saves the folder's exact original permissions first, then denies write/delete for your user, `SYSTEM` and `Administrators`. You keep read access.
- Block and allow both verify the result with a real write test. Running either twice is safe.
- If blocking fails halfway, it restores the original permissions right away. If another tool changed them, it shows a recovery option instead of overwriting.
- Permission errors are detected by error codes, not English message text, so it works in any Windows language.
- If Windows denies a change, only a small permission helper is elevated (UAC). The helper is hash-checked, re-checks the exact path itself, and never runs Spicetify. Spicetify and the menu are never elevated.
- Permission writes go through locked, validated folder handles, with no fallback by path name. Existing audit rules are left alone.

</details>

<details>
<summary><b>Linux update control, permissions and recovery</b></summary>

- **Flatpak:** masks only `com.spotify.Client` in the detected scope. **APT:** holds only `spotify-client`. Masks or holds that already existed are marked external and never removed.
- If Spicetify needs to write to system-owned Spotify files, the manager records the current owner and modes first. It loosens only Spotify's resource folder and its `Apps` folder, then restores them afterwards. Nothing is changed recursively on parent folders.
- Symlinked resources and incomplete permission records are refused. New files created during repair are left alone.
- `Ctrl+C`, `SIGTERM` and `SIGHUP` trigger cleanup and try to restore the previous block. If that can't finish, the saved state is kept and recovery is offered on the next run.
- Saved state is written atomically with private permissions. Symlinked, wrongly owned, group/world-writable or malformed state is refused.

</details>

<details>
<summary><b>Installing Spicetify</b></summary>

- Never replaces a package-managed Spicetify. Arch and Nix installs are left to their normal update process.
- Downloads the official installer ([Linux](https://raw.githubusercontent.com/spicetify/cli/main/install.sh) / [Windows](https://raw.githubusercontent.com/spicetify/cli/main/install.ps1)) over HTTPS to a private temp folder. It never pipes it straight into a shell.
- Before running it, checks the host, response type, size, syntax and expected structure, then shows you the URL and asks to confirm.
- These checks catch unexpected responses. They are not a signature or a guarantee about upstream content.
- Marketplace is only installed if you accept the separate upstream prompt.

</details>

<details>
<summary><b>File locations</b></summary>

| | Windows | Linux |
| --- | --- | --- |
| Saved state | `%LOCALAPPDATA%\SpicetifySpotifyManager` | `$XDG_STATE_HOME/spicetify-spotify-manager` (default `~/.local/state/…`) |
| Log | `…\manager.log` | `…/manager.log`: private (`0600`), size-limited, one rotated copy |

</details>

<details>
<summary><b>Testing status and limitations</b></summary>

- Automated tests run on Windows and Ubuntu in GitHub Actions on every push. Linux tests use fake Spotify folders and fake package tools, so they never touch a real system.
- **Not yet tested on real machines:** CachyOS, Flatpak with the Spotify GUI, Spotify login, and how Spicetify looks once applied. Progress is tracked in the [manual validation checklist](MANUAL-VALIDATION.md).
- Run one manager action at a time, and don't change Spotify's update blocks or permissions from another tool mid-run.
- The Windows 1.2.0 `.exe` is unsigned, so SmartScreen may warn on first run.

</details>

## Development

Edit the source in [`src/`](src). The root `.exe` and `.sh` files are generated, so don't edit them directly. Both share one version number in [`VERSION`](VERSION). Changes are listed in [`CHANGELOG.md`](CHANGELOG.md).

**Windows** (Windows PowerShell 5.1):

```powershell
.\build\Build-Release.ps1          # build
.\build\Build-Release.ps1 -Check   # verify the committed EXE matches
.\tests\Run-Tests.ps1
```

**Linux** (Bash + ShellCheck):

```bash
./build/build-linux-release.sh          # build
./build/build-linux-release.sh --check  # verify the committed script matches
shellcheck -x src/linux/core.sh src/linux/main.sh build/build-linux-release.sh tests/run-linux-tests.sh Spicetify-Spotify-Manager-Linux.sh
./tests/run-linux-tests.sh
```

<details>
<summary><b>Build details</b></summary>

- The Windows build is reproducible. It downloads a hash-pinned C# compiler and reference assemblies from `api.nuget.org` (listed in `build/windows-toolchain.json`), with no SDK install. The first build needs internet, and later builds can use the cache (`%TEMP%\SpicetifySpotifyManager-build-cache`, or `-ToolCache <dir>`).
- The PowerShell source is embedded in the EXE and tested byte-for-byte against `src/`.
- CI checks the EXE against `build/windows-release.sha256`. Only update that hash after deliberately changing and testing the source.
- Pushing a stable `vX.Y.Z` tag publishes a GitHub Release with both files and `SHA256SUMS`.

</details>

<details>
<summary><b>Research references and credits</b></summary>

These projects were used as references for ideas and correct behaviour. No code was copied from them, and listing them doesn't imply endorsement.

| Project | What I looked at |
| --- | --- |
| [spicetify/cli](https://github.com/spicetify/cli) + [docs](https://spicetify.app/docs/getting-started) | Source of truth for install paths, permissions and repair |
| [SpotX-Official/SpotX](https://github.com/SpotX-Official/SpotX) | Windows install detection and process handling |
| [SpotX-Official/SpotX-Bash](https://github.com/SpotX-Official/SpotX-Bash) | Linux argument handling and permission checks (no ad/client patches used) |
| [thomas-quant/BlockTheSpot-Resilient](https://github.com/thomas-quant/BlockTheSpot-Resilient) | Backup-first recovery |
| [Sriansh-raj/SpotX-Blocker](https://github.com/Sriansh-raj/SpotX-Blocker) | Older update-blocking approach |
| [Mspy1/Spotify-Update-Blocker](https://github.com/Mspy1/Spotify-Update-Blocker) | Historical example (archived, no longer works) |
| [Nuzair46/BlockTheSpot-Linux](https://github.com/Nuzair46/BlockTheSpot-Linux) | Linux detection and backups (archived, patching not used) |
| [kpcyrd/spotify-launcher](https://github.com/kpcyrd/spotify-launcher) | Paths, config and what `--skip-update` really does |
| [Gerg-L/spicetify-nix](https://github.com/Gerg-L/spicetify-nix) | The right approach for Nix/NixOS |
| [Flatpak](https://docs.flatpak.org/en/latest/tips-and-tricks.html#masking), [apt-mark](https://manpages.debian.org/unstable/apt/apt-mark.8.en.html), [ArchWiki](https://wiki.archlinux.org/title/Pacman) | Masks, holds, and avoiding partial Arch upgrades |

</details>

## Disclaimer and license

This is an unofficial personal tool. It isn't affiliated with or endorsed by Spotify or the Spicetify team. Changes to Spotify, Spicetify or Linux package managers may need updates here.

Released under the [MIT License](LICENSE).
