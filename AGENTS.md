# Development rules

Edit `src/SpicetifySpotifyManager.ps1`, `src/ElevatedAclHelper.ps1`, `src/DirectoryAcl.ps1`, `src/Launcher.cs`, and `src/linux/`. The root `.exe` and `.sh` are generated release files, not editable source. `VERSION` is shared by both platforms. The Windows EXE hosts the embedded PowerShell in-process and binds native arguments as an array; never reintroduce CMD forwarding or extracted CLI scripts.

Use Windows PowerShell 5.1 for `build/Build-Release.ps1`, `build/Build-Release.ps1 -Check`, and `tests/Run-Tests.ps1`. The builder uses hash-pinned build-only packages in `build/windows-toolchain.json`, not a globally installed SDK. Use Bash for `build/build-linux-release.sh`, its `--check` mode, and `tests/run-linux-tests.sh`. Run ShellCheck on both Linux sources, builder, tests, and generated script. Verify consecutive and clean builds match, embedded Windows source parity, Linux LF and executable mode. The EXE is binary. Update any recorded Windows hash only after validating the deliberate source change.

Keep disposable tests isolated from real Spotify, package holds/masks, account data, and graphical sessions. WSL mocks are not live GUI validation. Preserve unrelated and interrupted work; do not infer that an uncommitted implementation has passed validation.

Windows ACL operations must target only the validated Spotify `Update` directory and reject reparse-point ancestors. Preserve original descriptors and recovery state. The elevated helper must hash one byte read and execute only that same in-memory content. Never elevate Spicetify or the interactive manager.

Linux controls must retain external ownership and exact package scope. Reject unsafe state paths; retain recovery information when verification fails. Do not broaden package updates, remove unrelated permissions, add runtime dependencies, or edit generated scripts directly.

Do not commit, push, create tags, publish releases, force-push, or rewrite history without explicit user authorization. Automated test success is not release approval.
