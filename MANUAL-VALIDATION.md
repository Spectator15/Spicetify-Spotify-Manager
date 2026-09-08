# Manual validation for 1.2.0

`1.2.0` is unreleased. Every real-machine check below is **PENDING**. Automated fixture tests do not complete these checks. Record the tested OS, package scope, versions, date, and outcome without including account data or credentials. Mark a check passed only after the maintainer reports its result.

Use disposable profiles or recoverable test machines for permission, interruption, and recovery checks. Keep personal Spotify data out of destructive failure scenarios. Run one manager operation at a time, normally unelevated.

## Exact artifacts

Normal users need only the file for their platform, not source files or build tools. Verify these SHA-256 values before testing; stop if either differs.

| File | SHA-256 |
| --- | --- |
| `Spicetify-Spotify-Manager.exe` | `e93886217b140ba6a2a19fdda2b040d4a23b4d9d27207d593b7db1b564a202d8` |
| `Spicetify-Spotify-Manager-Linux.sh` | `384541593e26fdfd1d281b0bc86b2a04a93109218f9fd04854f8cf84d9d48deb` |

## Windows

- [ ] **PENDING** Copy both artifacts into a separate, normally protected folder, verify their hashes, and scan them with up-to-date Defender. Test the unsigned EXE's downloaded-file/SmartScreen behaviour without disabling protection. Record any detection name, file hash, affected path, timestamp, and Defender engine/signature versions privately. A heuristic label alone does not prove a false positive; review the matching source and submit the exact artifact to Microsoft only if investigation supports that conclusion.
- [ ] **PENDING** On the intended Windows/.NET Framework 4.8/Windows PowerShell 5.1 environment, run the EXE alone from Explorer, Command Prompt, and PowerShell. Check the menu, console output, `--help`, `--version`, read-only `--status`, documented exit codes, and paths containing spaces and Unicode.
- [ ] **PENDING** Check an existing manager-state directory before normal use. If its ownership or ACL is rejected, investigate the original state rather than bypassing validation or granting broader access. Confirm a Microsoft Store-only installation is reported without modification.
- [ ] **PENDING** In a disposable standalone Spotify installation, record the original Update directory owner, group, DACL, and unrelated files. Check block twice, allow twice, recovery, and exact restoration. Confirm other directories remain untouched.
- [ ] **PENDING** Exercise genuine UAC approval and cancellation for an ACL write that actually requires it in a disposable Windows environment. Verify only the ACL helper is elevated, failed/cancelled retries leave no temporary helper behind, and Spicetify and the interactive manager remain unelevated. Mocked UAC tests are not equivalent.
- [ ] **PENDING** Exercise installation/update of Spicetify and the guided Spotify update/repair with a graphical standalone client. Confirm appropriate close/relaunch behaviour, final update preference, visual application, and preservation of existing settings, themes, extensions, and Marketplace. Check failed repair and interrupted recovery on a recoverable test machine.

## Linux

- [ ] **PENDING** Run the SH alone as a normal user on a graphical Linux machine, including CachyOS. Verify `chmod +x` after download, menu/CLI output, spaces and Unicode paths, diagnostics, private logs, and refusal to run the complete manager as root.
- [ ] **PENDING** Test real Flatpak Spotify separately in user and system scope. Check discovery, absolute paths, repeated mask/allow operations, preservation of external masks, refusal of ambiguous dual installations, and an update affecting only the selected Spotify application.
- [ ] **PENDING** Test official APT `spotify-client` on Debian/Ubuntu. Verify existing external holds are preserved, manager-owned holds are reversible, only Spotify is requested for update, and privilege is limited to the required package/resource operation.
- [ ] **PENDING** Check native Arch/AUR detection and repair without manager-driven partial/system upgrades. Check `spotify-launcher` separately, including the honest launch-only scope of `--skip-update`, the correct relaunch command, and unchanged launcher configuration.
- [ ] **PENDING** Confirm Snap refusal, Nix/NixOS guidance, unknown/ambiguous-installation refusal, and verified manual-path repair without claims of package update control on appropriate test environments.
- [ ] **PENDING** Exercise graphical Spicetify apply/repair and a guided Spotify update. Confirm appearance, process/running-state restoration, configuration and Marketplace preservation, and restoration of temporary resource permissions.
- [ ] **PENDING** On a recoverable test installation, interrupt or fail an update/repair and verify recovery on the next run, previous mask/hold restoration, exact saved permission restoration, and useful private logs. Do not alter package controls concurrently from another tool.

## Release gate

- [ ] **PENDING** Review the manual results and successful Windows/Ubuntu CI for the exact proposed commit. Resolve failures or document untested environments honestly; obtain explicit release approval before tagging or publishing.
- [ ] **PENDING** At publication, update the Windows latest-download link to the EXE, publish both exact artifacts and checksums, and re-download them to verify byte identity. Preserve existing `v1.1.0` tags, release assets, and historical BAT references.
