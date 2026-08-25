<h1 align="center">Spicetify Spotify Manager</h1>

<p align="center">A small Windows utility for managing Spicetify and Spotify desktop updates.</p>

---

## Why this exists

I use [Spicetify](https://github.com/spicetify/cli) with the Spotify desktop client. Spotify updates can sometimes require Spicetify to be reapplied, so I made this small Windows utility to control when those updates happen.

## What the script does

The `Spicetify-Spotify-Manager.bat` script can:

- Install or update Spicetify through the official Spicetify CLI installer.
- Close Spotify when necessary.
- Deliberately block Spotify desktop updates.
- Restore normal update access when I am ready to update.

## Normal workflow

1. Keep Spotify updates blocked during normal use.
2. When I intentionally want to update Spotify, unblock updates with the script.
3. Open Spotify and let it update.
4. Close Spotify.
5. Reapply Spicetify if needed, usually with:

   ```powershell
   spicetify backup apply
   ```

6. Block Spotify updates again.

## Usage

1. Download [`Spicetify-Spotify-Manager.bat`](Spicetify-Spotify-Manager.bat).
2. Run it normally.
3. Choose an option from the numbered menu.

## Important information

> [!IMPORTANT]
> Update blocking works by controlling access only to `%LOCALAPPDATA%\Spotify\Update`. The script is intended for the normal Windows desktop client downloaded from `spotify.com`. It is **not** intended for the Microsoft Store version.

> [!TIP]
> If Windows reports a permissions error while blocking or unblocking updates, retry that action by running the script as administrator.

## Privacy

The script does not access Spotify passwords, account information, credentials, or tokens. It includes no telemetry or analytics.

---

## Disclaimer and license

This is an unofficial personal utility. It is not affiliated with or maintained by Spotify or the Spicetify developers. Changes to Spotify or Spicetify may eventually require this script to be updated.

This repository is provided under the [MIT License](LICENSE).
