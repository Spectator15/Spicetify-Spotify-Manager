# Changelog

## 1.2.0 (pending release review)

- Added `--help`, `--version`, and read-only `--status` commands to the Windows manager.
- Strengthened Windows official-installer validation with bounded size, response, syntax, structure, and official release-reference checks.
- Replaced locale-dependent permission-message matching with structured exception, error-category, `HResult`, and Win32-code handling.
- Limited Windows UAC retry to an integrity-checked ACL helper whose verified in-memory bytes are executed without a second file read.
- Bound normal and elevated Windows ACL writes to validated directory handles, with ancestor sharing locks and no path-based mutation fallback.
- Added a private, timestamped, size-bounded Linux log inside the existing XDG state directory.
- Moved both generated managers to one project version stored in `VERSION`.
- Fixed Windows PowerShell 5.1 test parsing, normalized only the Windows DACL auto-inheritance bookkeeping flag during verification, and rejected junctions in target ancestors.
- Replaced the Windows BAT entry point with one deterministic .NET Framework EXE that hosts PowerShell 5.1 in-process, binds the native argument array directly, and needs no extracted CLI wrapper. Added exact argument round-trip and injected-side-effect regression tests.
- Hardened temporary cleanup against directory-junction traversal.
- Hardened state reads, interrupted-control detection, package-query error propagation, and permission-manifest validation on Linux.
- Kept declined recovery state, stopped guided actions after failed stage writes, and preserved exact Flatpak launch scope and new-deployment recovery.
- Reduced Linux status to one package-control query and permission snapshots to one `stat` call per resource entry.
- Added bounded Linux installer validation and conservative refusal of broader external Spotify mask patterns.
- Kept permission restoration available when a failed repair has removed Spotify's `xpui` resources, without relaxing path or manifest validation.

## 1.1.0

- Added the package-aware Linux manager with Flatpak and APT update control, safe recovery state, Linux tests, and separate Windows and Linux release files.
