<h1 align="center">Spicetify Spotify Manager</h1>

<p align="center">A small Windows utility for managing Spicetify and controlling standalone Spotify desktop updates.</p>

---

## Why this exists

I use [Spicetify](https://github.com/spicetify/cli) with the Spotify desktop client. Spotify updates can sometimes require Spicetify to be reapplied, so I made this utility to control when those updates happen and make the normal recovery workflow less repetitive.

The manager stays focused on the official standalone Spotify client downloaded from `spotify.com`. It does not patch Spotify binaries, block advertisements, unlock Spotify features, install a different Spotify build, or modify account and subscription behaviour.

## What it does

The ready-to-run [`Spicetify-Spotify-Manager.bat`](Spicetify-Spotify-Manager.bat) shows the current Spotify, Spicetify, process, and update-access state before presenting a compact numbered menu.

It can install or update Spicetify from the official project, reapply Spicetify when Spotify has replaced its app files, block or restore Spotify updates, and guide the normal update process while preserving the previous update-blocking and running-state preferences.

| Menu action | Purpose |
| --- | --- |
| **Guided Spotify update and Spicetify repair** | Temporarily allows updates, opens Spotify, checks the resulting state, reapplies Spicetify only when needed, then restores the previous update preference. |
| **Install or update Spicetify CLI** | Uses the official Spicetify installer when the CLI is missing, or the official CLI update command when it is already installed. |
| **Reapply or repair Spicetify** | Closes Spotify only when required, runs the supported backup and apply workflow, verifies the app state, and restores Spotify's previous running state. |
| **Block Spotify updates** | Applies and verifies a narrowly scoped managed ACL on the standalone client's `Update` directory. |
| **Allow Spotify updates** | Restores the exact ACL saved before blocking and verifies write access. |

## Download and usage

> [!IMPORTANT]
> This manager supports the normal Windows desktop client downloaded from `spotify.com`. The Microsoft Store version is detected but is not modified. If only the Store version is installed, the manager explains that the configuration is unsupported and stops safely.

1. Download the complete [`Spicetify-Spotify-Manager.bat`](https://github.com/Spectator15/Spicetify-Spotify-Manager/releases/latest/download/Spicetify-Spotify-Manager.bat) release asset.
2. Run the batch file normally, not as administrator.
3. Review the displayed status and choose an action from the numbered menu.

Windows PowerShell 5.1 is required. Normal Spicetify commands are never run elevated. If Windows denies a permission change, the manager can request administrator approval for that specific ACL retry only.

## Recommended workflow

During normal use, keep Spotify updates blocked. When I intentionally want to update Spotify:

1. Choose **Guided Spotify update and Spicetify repair**.
2. Let the manager close Spotify if it is running and temporarily restore update access.
3. Wait for Spotify to open and finish updating normally.
4. Return to the manager when Spotify is fully usable and press Enter.
5. Let the manager close Spotify, check whether Spicetify needs repair, and reapply it only when needed.
6. The manager restores the previous update-blocking preference and relaunches Spotify only if it was running before the workflow.

Spotify does not provide this utility with a supported update-completion API, so the guided workflow waits for a real user confirmation instead of relying on an arbitrary delay or claiming an update finished when it cannot verify that.

The same steps remain available as separate menu actions when I want manual control. The supported Spicetify recovery command is based on the official workflow:

```powershell
spicetify backup apply --no-restart
```

## How update blocking works

> [!WARNING]
> Every ACL safety check and permission operation is restricted to `%LOCALAPPDATA%\Spotify\Update`. A path that does not exactly match that location, or an `Update` directory that is a junction or other reparse point, is refused before permissions are changed.

Before blocking, the manager records the directory's exact original security descriptor under `%LOCALAPPDATA%\SpicetifySpotifyManager`. It then adds known SID-based rules for the current user, `SYSTEM`, and `Administrators`. The current user keeps read and execute access while explicit write and delete access is denied. Existing unrelated files are not deleted, and inherited or unrelated permissions are restored from the saved descriptor rather than guessed later.

Both block and allow actions verify their final ACL and perform a real write-access probe. Repeating either action is safe. If blocking fails partway through, the manager attempts to restore the original ACL immediately and reports the underlying Windows error.

If the manager is interrupted or detects that another tool changed the ACL, it shows a recovery state instead of silently overwriting those changes. The recovery menu can deliberately restore the saved original ACL after confirmation.

## Recovery and troubleshooting

To restore normal Spotify update behaviour, choose **Allow Spotify updates**. If a guided workflow fails, the manager first tries to restore its previous update and running-state preferences immediately. If that recovery is interrupted or cannot finish, start the manager again and follow the saved recovery prompt. A concise diagnostic log is stored at `%LOCALAPPDATA%\SpicetifySpotifyManager\manager.log`.

If Spicetify is no longer applied after a Spotify update, use **Reapply or repair Spicetify**. The manager first tries the normal `backup apply` workflow, then uses the official restore and fresh-backup sequence if the first command fails. Command output is shown when it is needed for diagnosis.

The manager does not remove Spotify data, login information, playlists, Spicetify configuration, themes, extensions, or Marketplace files. It does not access Spotify passwords, account information, credentials, or tokens, and it includes no telemetry or analytics.

## Development

Normal users need only the root batch file. The committed [`Spicetify-Spotify-Manager.bat`](Spicetify-Spotify-Manager.bat) is generated deterministically from the small batch launcher and the Windows PowerShell 5.1 source in `src`. Developers should edit those source files, not the generated batch.

Build and validate the release from Windows PowerShell:

```powershell
.\build\Build-Release.ps1
.\build\Build-Release.ps1 -Check
.\tests\Run-Tests.ps1
```

The dependency-free tests use temporary Spotify-shaped directories, mocks, and genuine Windows ACL operations. They do not test against or alter the real Spotify or Spicetify installation. The Windows GitHub Actions workflow runs the same build and test checks.

## Research references

The implementation was written independently using normal Windows and official Spicetify behaviour. No source code was copied or adapted from the reference projects. They were reviewed for engineering ideas only, and their inclusion here does not imply endorsement.

- [Mspy1/Spotify-Update-Blocker](https://github.com/Mspy1/Spotify-Update-Blocker), an archived historical minimal example whose README says its old method no longer works.
- [thomas-quant/BlockTheSpot-Resilient](https://github.com/thomas-quant/BlockTheSpot-Resilient), reviewed for backup-first recovery and automated compatibility checking.
- [SpotX-Official/SpotX](https://github.com/SpotX-Official/SpotX), reviewed for installation detection, parameterized functions, process handling, validation, and Windows automation.
- [Sriansh-raj/SpotX-Blocker](https://github.com/Sriansh-raj/SpotX-Blocker), a SpotX-derived project reviewed for the differences in its historical update-blocking approach.
- [spicetify/cli](https://github.com/spicetify/cli) and the [official Spicetify documentation](https://spicetify.app/docs/getting-started), used as the source of truth for supported Spicetify installation and repair behaviour.

## Disclaimer and licence

This is an unofficial personal utility. It is not affiliated with, endorsed by, or maintained by Spotify, the Spicetify developers, or any research-reference project. Changes to Spotify or Spicetify may eventually require this manager to be updated.

This repository is provided under the [MIT License](LICENSE).
