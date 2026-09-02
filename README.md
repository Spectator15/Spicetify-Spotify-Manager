<h1 align="center">Spicetify Spotify Manager</h1>

<p align="center">A small Windows and Linux utility for managing Spicetify and controlling when supported Spotify desktop packages update.</p>

---

## Why this exists

I use [Spicetify](https://github.com/spicetify/cli) with the Spotify desktop client. Spotify updates can sometimes require Spicetify to be reapplied, so I made this utility to control when those updates happen and make the normal recovery workflow less repetitive.

The manager stays focused on Spotify and Spicetify maintenance. It does not patch Spotify binaries, block advertisements, unlock Spotify features, install a different Spotify build, or modify account and subscription behaviour.

## What it does

Both ready-to-run files show the current Spotify, Spicetify, process, and update-control state before presenting a compact numbered menu.

| Menu action | Purpose |
| --- | --- |
| **Guided Spotify update and Spicetify repair** | Temporarily allows an intentional update where supported, updates only Spotify, checks Spicetify, and restores the previous update and running-state preferences. |
| **Install or update Spicetify CLI** | Uses the official Spicetify source or the existing package manager without replacing a package-managed installation. |
| **Reapply or repair Spicetify** | Closes Spotify only when required, runs the supported backup and apply workflow, verifies the result, and restores Spotify's previous running state. |
| **Block or control Spotify updates** | Uses the platform's supported, narrowly scoped mechanism and records only control created by this manager. |
| **Allow Spotify updates** | Removes only update control owned by this manager. Existing external Flatpak masks or APT holds are preserved. |
| **Show detailed diagnostics** | Shows detected paths, package type, versions, state location, and relevant commands without changing the system. |

## Download and usage

The stable `v1.1.0` release contains separate complete files for Windows and Linux:

- [Download the Windows manager](https://github.com/Spectator15/Spicetify-Spotify-Manager/releases/latest/download/Spicetify-Spotify-Manager.bat)
- [Download the Linux manager](https://github.com/Spectator15/Spicetify-Spotify-Manager/releases/latest/download/Spicetify-Spotify-Manager-Linux.sh)

### Windows

> [!IMPORTANT]
> The Windows manager supports the normal standalone desktop client downloaded from `spotify.com`. The Microsoft Store version is detected but is not modified.

Run `Spicetify-Spotify-Manager.bat` normally, not as administrator. Windows PowerShell 5.1 is required. Normal Spicetify commands are never run elevated. If Windows denies a permission change, the manager can request administrator approval for that specific ACL retry only.

### Linux

Make the downloaded file executable if your browser removed its executable bit, then run it as your normal user:

```bash
chmod +x Spicetify-Spotify-Manager-Linux.sh
./Spicetify-Spotify-Manager-Linux.sh
```

Do not run the complete manager with `sudo`. It refuses root execution during normal operation and requests privilege only for an exact APT or Spotify-resource permission command that needs it.

The command-line status options are useful for diagnostics and scripts:

```bash
./Spicetify-Spotify-Manager-Linux.sh --help
./Spicetify-Spotify-Manager-Linux.sh --version
./Spicetify-Spotify-Manager-Linux.sh --status
```

`--status` returns `0` for a supported detected installation and `3` for unsupported, ambiguous, or missing Spotify. Usage errors return `64`, missing requirements return `69`, operation failures return `70`, permission failures return `77`, and unsafe or corrupt state returns `78`.

Linux requires Bash, standard GNU file utilities, `find`, `stat`, `realpath`, and `pgrep`. The detected package manager must also be available. `curl` is needed only when downloading the official Spicetify installer, and `sudo` is needed only for supported system-level APT or permission operations.

## Linux package support

> [!IMPORTANT]
> Flatpak is the recommended Spotify configuration on CachyOS for this manager. It provides explicit installation scopes, an application-specific update command, and Flatpak's supported mask mechanism.

| Spotify installation | Spicetify | Update control | Guided update |
| --- | --- | --- | --- |
| **Flatpak, user scope** | Supported with verified absolute paths | Exact `com.spotify.Client` user mask | Updates only `com.spotify.Client` in user scope |
| **Flatpak, system scope** | Supported, with narrowly scoped temporary permission handling when required | Exact `com.spotify.Client` system mask | Updates only `com.spotify.Client` in system scope |
| **Official APT `spotify-client`** | Supported after verification through `dpkg` | `apt-mark hold` and `apt-mark unhold` for `spotify-client` only | Uses `apt-get install --only-upgrade -- spotify-client` |
| **Arch, CachyOS, or AUR native package** | Detection and repair are supported | Externally managed | The manager waits for the normal complete Arch/AUR update workflow and never performs a partial system update |
| **`spotify-launcher`** | Detection, absolute path configuration, launch, and repair are supported | `--skip-update` only for launches started through this manager | Uses `spotify-launcher --check-update --no-exec` |
| **Manual verified path** | Status and repair only | Unavailable | The original installation method remains responsible for updates |
| **Snap** | Unsupported | Unavailable | Refused because official Spicetify guidance says Snap application files cannot be modified |
| **Nix or NixOS** | Use [`spicetify-nix`](https://github.com/Gerg-L/spicetify-nix) | Declaratively managed | Not changed by this manager |

If both user and system Flatpak Spotify installations exist, or more than one package type is detected, the manager reports an ambiguous configuration and refuses to choose silently. A manual path can be supplied with `--spotify-path` and `--prefs-path`, but it must be absolute, contain verified Spotify `Apps` resources, and contain no symlink escape. Manual paths never gain package-manager update control.

`spotify-launcher --skip-update` does not block launches made from another desktop file or command. The manager does not replace desktop files, create wrappers, or change the launcher's existing configuration.

## Recommended workflow

During normal use, keep Spotify updates controlled where the installation type supports it. When I intentionally want to update Spotify:

1. Choose **Guided Spotify update and Spicetify repair**.
2. Let the manager close Spotify if it is running and temporarily restore update access where necessary.
3. Let it update only the detected Spotify package, or complete the normal external Arch/AUR update when prompted.
4. Let the manager configure verified absolute paths and reapply Spicetify only when needed.
5. The manager restores the previous update-control preference.
6. Spotify is relaunched only when it was running before the workflow, using the detected package's launch method.

The manager polls real process state instead of using a fixed delay to claim Spotify opened or closed. On package types where the manager cannot prove an external update completed, it waits for explicit user confirmation.

The supported Spicetify recovery commands are based on the current official workflow:

```bash
spicetify backup apply --no-restart
spicetify restore backup apply --no-restart
```

## Update-control ownership and recovery

On Flatpak, the manager masks only `com.spotify.Client` in the detected user or system scope. On APT, it holds only `spotify-client`. A mask or hold that existed before the manager is labelled external and is never removed by the normal **Allow Spotify updates** action.

On Linux, managed state is stored under `${XDG_STATE_HOME}/spicetify-spotify-manager`, or `~/.local/state/spicetify-spotify-manager` when `XDG_STATE_HOME` is unset. Files are written atomically with private permissions. Symlinked, unexpectedly owned, group-writable, world-writable, malformed, or mismatched state is refused.

The guided workflow records its package type, scope, previous control state, previous Spotify running state, launch method, path, and current stage before changing anything. `SIGINT`, `SIGTERM`, and `SIGHUP` trigger cleanup and an attempt to restore the previous update state. If recovery cannot finish, valid state remains for the next run and the manager offers recovery before normal actions.

When Spicetify needs write access to system-owned Spotify resources, the Linux manager validates the exact installation first and records modes and ownership. Any broader write bits are temporary, apply only to the exact Spotify resource root and its `Apps` directory, and are restored after the operation. No recursive permission command targets a parent directory or an unrelated application.

The manager never deletes Spotify data, login information, playlists, preferences, Spicetify configuration, themes, extensions, or Marketplace files. It does not access Spotify passwords, account information, credentials, or tokens, and it includes no telemetry or analytics.

## Windows update blocking

> [!WARNING]
> Every Windows ACL safety check and permission operation is restricted to `%LOCALAPPDATA%\Spotify\Update`. A path that does not exactly match that location, or an `Update` directory that is a junction or other reparse point, is refused before permissions are changed.

Before blocking, the Windows manager records the directory's exact original security descriptor under `%LOCALAPPDATA%\SpicetifySpotifyManager`. It then adds known SID-based rules for the current user, `SYSTEM`, and `Administrators`. The current user keeps read and execute access while explicit write and delete access is denied. Inherited and unrelated permissions are restored from the saved descriptor instead of being guessed later.

Both block and allow actions verify the final ACL and perform a real write-access probe. Repeating either action is safe. If blocking fails partway through, the manager attempts to restore the original ACL immediately and reports the underlying Windows error.

If the manager is interrupted or detects that another tool changed the ACL, it shows a recovery state instead of silently overwriting those changes. The recovery menu can deliberately restore the saved original ACL after confirmation. A concise diagnostic log is stored at `%LOCALAPPDATA%\SpicetifySpotifyManager\manager.log`.

## Spicetify installation

The manager does not replace a package-managed Spicetify installation with another method. Package-owned installations are updated through the appropriate package workflow where it is safe to do so. Arch and Nix-managed installations are left to their normal declarative or complete system update process.

When the Linux CLI is missing, the manager downloads the exact [official Spicetify installer](https://raw.githubusercontent.com/spicetify/cli/main/install.sh) over HTTPS into a private temporary directory. It fails on HTTP errors, checks the expected shell source, displays the source URL, asks for confirmation, executes the saved local file, and cleans it afterward. It never runs remote content through `curl | sh` itself. Marketplace is preserved and is not installed or modified unless the user explicitly accepts the separate upstream installer prompt.

If the current Spotify version is newer than Spicetify supports, the official Spicetify command may refuse to apply. The manager shows that diagnostic and does not claim success.

## Development and validation

Normal users need only one platform file from the release. The committed root files are generated deterministically from editable source under `src`. Developers should edit the source, not the generated files.

Build and test Windows from Windows PowerShell 5.1:

```powershell
.\build\Build-Release.ps1
.\build\Build-Release.ps1 -Check
.\tests\Run-Tests.ps1
```

Build and test Linux with Bash and ShellCheck:

```bash
./build/build-linux-release.sh
./build/build-linux-release.sh --check
shellcheck -x src/linux/core.sh src/linux/main.sh build/build-linux-release.sh tests/run-linux-tests.sh Spicetify-Spotify-Manager-Linux.sh
./tests/run-linux-tests.sh
```

The Linux tests use disposable Spotify-shaped directories and fake executables placed first in a temporary `PATH`. They do not alter real Flatpak masks, APT holds, packages, Spotify files, credentials, or graphical sessions. The suite runs on Ubuntu in GitHub Actions and was also run in the Ubuntu WSL 2 Linux filesystem, including executable bits, LF endings, case-sensitive paths, spaces, Unicode, symlink refusal, atomic replacement, deterministic generation, direct execution, and real signal handling.

WSL and Ubuntu automation do not prove graphical Spotify behaviour on every distribution. Real CachyOS, Flatpak GUI, Spotify login, and visual Spicetify testing remain outstanding. The manager reports package-specific limits rather than treating those environments as already proven.

CI also rebuilds and runs all Windows tests on a Windows runner. It enforces the recorded Windows release SHA-256 and CRLF line endings so Linux generation cannot change the Windows release bytes.

## Research references

The Windows and Linux implementations were written independently using normal platform tools and official Spicetify behaviour. No source code was copied or adapted from the reference projects. They were reviewed for engineering ideas only, and their inclusion does not imply endorsement.

Windows research references:

- [Mspy1/Spotify-Update-Blocker](https://github.com/Mspy1/Spotify-Update-Blocker), an archived historical minimal example whose README says its old method no longer works.
- [thomas-quant/BlockTheSpot-Resilient](https://github.com/thomas-quant/BlockTheSpot-Resilient), reviewed for backup-first recovery and automated compatibility checking.
- [SpotX-Official/SpotX](https://github.com/SpotX-Official/SpotX), reviewed for installation detection, parameterized functions, process handling, validation, and Windows automation.
- [Sriansh-raj/SpotX-Blocker](https://github.com/Sriansh-raj/SpotX-Blocker), a SpotX-derived project reviewed for the differences in its historical update-blocking approach.

Linux research references:

- [Nuzair46/BlockTheSpot-Linux](https://github.com/Nuzair46/BlockTheSpot-Linux), an archived client-patching project reviewed only as a historical Linux detection and backup example. Its patching and broad filesystem search were not used.
- [SpotX-Official/SpotX-Bash](https://github.com/SpotX-Official/SpotX-Bash), reviewed for Linux argument handling, resource validation, backups, permission diagnostics, and process-aware operation. Its advertising and client patches were not used.
- [kpcyrd/spotify-launcher](https://github.com/kpcyrd/spotify-launcher), used to verify current installation paths, configuration precedence, and the limited meaning of `--skip-update`.
- [Gerg-L/spicetify-nix](https://github.com/Gerg-L/spicetify-nix), used as the appropriate declarative direction for Nix and NixOS users.
- [Flatpak documentation](https://docs.flatpak.org/en/latest/tips-and-tricks.html#masking), [Debian's `apt-mark` manual](https://manpages.debian.org/unstable/apt/apt-mark.8.en.html), and [ArchWiki package-management guidance](https://wiki.archlinux.org/title/Pacman), used as the source of truth for masks, holds, and the avoidance of unsupported Arch partial upgrades.
- [spicetify/cli](https://github.com/spicetify/cli) and the [official Spicetify documentation](https://spicetify.app/docs/getting-started), used as the source of truth for installation paths, permissions, supported package types, and repair behaviour.

## Disclaimer and licence

This is an unofficial personal utility. It is not affiliated with, endorsed by, or maintained by Spotify, the Spicetify developers, or any research-reference project. Changes to Spotify, Linux package managers, or Spicetify may eventually require this manager to be updated.

This repository is provided under the [MIT License](LICENSE).
