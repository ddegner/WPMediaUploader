# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

## [1.1] - 2026-08-05

### Added
- Local AVIF generation ("Generate AVIFs locally" per-profile toggle): after each JPEG imports, the app encodes AVIF versions of the original and every WordPress-generated thumbnail size on the Mac, then sideloads them into the site's uploads directory next to the JPEGs.
- Embedded `avifenc` helper (static libavif + aom) so AVIF encoding honors quality, speed, chroma subsampling, and bit-depth settings; falls back to the system ImageIO encoder when the helper is unavailable.
- Integration with the AVIF Local Support WordPress plugin: the app reads the plugin's encoder settings (`aviflosu_*` options) so locally encoded AVIFs match server-side settings, runs imports with `--skip-plugins=avif-local-support` to prevent double encoding, and triggers LQIP placeholder generation after sideloading.
- Size verification for every sideloaded AVIF and a new `sideloading` pipeline stage with per-file status, retry, and interruption recovery.
- Resume-friendly uploads: interrupted rsync transfers keep partial files and resume via delta transfer; pushes into live uploads directories use whole-file replace.
- Automatic retry for transient rsync failures (protocol/timeout/SSH connection errors).
- Batched remote file-size checks (one SSH round trip for all AVIF derivatives).
- CI test workflow (`.github/workflows/test.yml`) running `swift test` on pushes.
- Orchestration test suite driving the full upload pipeline against a scripted command executor, plus unit tests for AVIF plugin-settings parsing.

### Changed
- macOS 26 (Tahoe) look and feel: Liquid Glass chrome, first-class file rows, undo for queue edits, continuous log selection, and drawer state fixes.
- Minimum deployment target raised to macOS 26.
- App termination is guarded while an upload is running; quitting now waits for ssh/rsync child processes to be torn down.
- SSH askpass secrets now pass through the Keychain instead of environment variables.
- Remote job-directory cleanup refuses paths that don't match the expected per-job UUID shape.
- `JobRunner` pipeline refactored: shared per-stage runner (guard → step transition → cancellation-aware failure capture → progress recalculation) with per-stage workers, and AVIF preflight split into testable units.

## [1.0.1] - 2026-03-13

### Added
- GitHub Actions release automation at `.github/workflows/release-package.yml` to build/sign/notarize/staple on tag pushes, publish GitHub Release assets, and publish a GHCR package containing the release zip + checksum.
- `scripts/app_store_resubmit.sh` to update App Store metadata and submit versions for review, with explicit credential/version inputs and `umask 077`.
- `APP_STORE_CONNECT_SUBMISSION_RUNBOOK.md` and `APP_STORE_METADATA.md` for repeatable App Store Connect submission and metadata remediation steps.
- Per-profile color coding with preset palette and context-menu color picker in the sidebar.
- Drag-to-reorder support for queued files in the workbench file list.
- Confirmation dialogs for destructive actions: delete profile, reset queue, and clear job history.
- "Add Files" toolbar button for adding files without drag-and-drop.
- `SecretStoring` protocol and `KeychainSecretStore` for testable Keychain access.
- `ColorHelpers.swift` utility with `Color(hexString:)` and `hexStringValue`.
- `LogWriterTests` and `ProfileStoreTests` with mock secret store for transactional save/rollback coverage.
- Empty-state drop zone overlay with dashed border and "Drop images here" placeholder in the file list.

### Changed
- `scripts/build_distribution.sh` now publishes a GitHub Release by default: it ensures `v<version>` tag alignment with `HEAD`, pushes the tag to `origin`, and creates/updates the release with `WPMediaUploader-v<version>-macOS.zip` plus `sha256.txt`.
- `scripts/build_distribution.sh` now defaults `NOTARY_KEYCHAIN_PROFILE` to `notary-profile` (still overrideable via env).
- Starting an upload no longer forces the operations drawer open; if the drawer is hidden, it remains hidden.
- Queue row status now shows `PREFLIGHT` during preflight, uses an in-progress spinner for preflight rows, and aligns preflight hover text with active preflight processing.
- Operations drawer now uses SwiftUI `.inspector()` modifier with resizable column (280–400pt) instead of manual HStack layout.
- Active job panel uses `Form` with `LabeledContent` instead of a custom metrics grid.
- `FocusedValues` entries use `@Entry` macro instead of verbose `FocusedValueKey` boilerplate.
- Sidebar profile list uses `ControlGroup` for add/remove buttons and removes the explicit "PROFILES" section header.
- Operations drawer tab picker, terminal header, and job history header use standard SwiftUI controls (`ControlGroup`, `ContentUnavailableView`).
- Drawer window-state persistence moved from `@AppStorage` to manual `UserDefaults` reads in `onAppear` to avoid spurious re-renders.
- `JobPresentation` ETA/Rate lines no longer include label prefixes (now handled by `LabeledContent` in the UI).
- `app_store_resubmit.sh` now supports build attachment, encryption declaration, and review notes upload.
- Bumped build number to 7.
- SSH authentication now uses the app binary itself as `SSH_ASKPASS` helper instead of temporary shell scripts, which the App Sandbox blocked from being exec'd.
- Remote WP-CLI commands auto-detect versioned PHP binaries (`php8.1`–`php8.4`) via `WP_CLI_PHP` to work on servers without a plain `php` symlink.
- SSH remote commands now execute inside a login shell (`bash -lc`) so the server's full `PATH` is available.
- Custom app entry point via `main.swift` replaces `@main` to support `SSH_ASKPASS` helper mode.

### Fixed
- Job log files now flush queued writes before a run exits, preventing missing log tails at job completion.
- In-flight jobs are no longer deleted on app termination, so interrupted uploads remain recoverable on next launch.
- Profile saves now apply Keychain changes atomically with profile persistence; the editor stays open and shows an alert if credential storage fails.
- Rsync file transfers now automatically retry once on transient errors (exit codes 12, 23, 30, 255) after a 2-second delay.
- `ProfileStore` and `JobStore` surface persistence errors to the UI via `lastError` and use `os.Logger` instead of `print()`.

### Security
- `SSH_ASKPASS` now uses the signed app binary rather than dynamically-created shell scripts, eliminating writable temp files containing secrets.
- Release workflow now explicitly cleans imported signing credentials (temporary keychain and `.p12`) at job end.

## [1.0] - 2026-02-17

### Added
- Icon-only operations tab selector with larger hit targets and full-width layout in the right drawer.
- New `scripts/build_distribution.sh` release workflow that signs with Developer ID, notarizes, staples, and sends a completion notification.

### Changed
- Unified Active Job, Terminal, and Job History empty-state presentation with centered messaging and consistent drawer styling.
- Updated operations tab icon mapping (Active Job now uses `hourglass` instead of a play glyph).
- Bumped app version to `1.0` and build number to `4`.
- Updated README download/version references for the `v1.0` release artifact.
- Published `WPMediaUploader-v1.0-macOS.zip` as a Developer ID signed and notarized macOS binary.

### Fixed
- Reduced excess top spacing in the right operations drawer header area for better visual balance.

## [0.9] - 2026-02-16

### Added
- Per-file `imported` progress state in the queue UI to clearly separate import completion from thumbnail regeneration completion.
- Richer file status help text for uploaded, verified, imported, regenerated, and failed states.

### Changed
- Job status labels now render with title-cased step text for improved readability.
- Profile connection test action now shows its progress indicator in the profile editor row where the test is initiated.
- Published `WPMediaUploader-v0.9-macOS.zip` as a Developer ID signed and notarized macOS binary.

### Fixed
- Import loop now regenerates thumbnails immediately after each successful WordPress import.
- Import progress updates are now applied consistently via shared progress update handling.
- Regeneration failures now emit timeout-aware error messages and preserve clear per-file failure context.

## [0.8] - 2026-02-16

### Added
- New macOS App Store asset set under `screenshots/app-store/macos/` in 1280x800, 2560x1600, and 2880x1800 variants.
- App Store icon export at `screenshots/app-store/macos/app-icon/app-icon-1024.png`.

### Changed
- App display/product name now uses `WP Media Uploader`.
- Updated release copy and metadata strings to match the new branding and macOS-focused description.
- Refreshed README screenshots and `app-screenshot.png` captures from the latest app build.
- Updated project marketing version to `0.8` and build number to `2`.

## [0.7] - 2026-02-14

### Added
- Completion sound toggle in app commands (`Play Sound on Completion`).
- Focused drawer command bindings for profile and operations drawers.
- Refined operations drawer tab control with icon-based segmented control.
- Expanded README screenshots for overview, queue status, and profile setup.

### Changed
- Updated app icon set assets.
- Updated app version to `0.7`.
- Refined content layout and actions in the main workbench UI.
- Profile selection is now handled in `ContentView` UI state.
- `CommandRunner` output collection now emits lines outside the lock to avoid callback re-entry while locked.
- `LogWriter` now computes timestamp/payload within its serialization queue.

### Fixed
- Interrupted jobs are preserved and recoverable instead of being removed during store initialization.
- Regeneration step now targets only successfully imported items for retry correctness.
- Retry progress calculation now reflects already-processed files before re-running failed work.
- In-flight job recovery now always marks interrupted pipeline jobs as failed with a clear reason.

## [0.6] - 2026-02-14
- Prior release baseline (`v0.6` tag).

## [0.5] - 2026-02-13
- First tagged release (`v0.5` tag).
