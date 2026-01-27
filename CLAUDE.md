# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ImmiBridge is a native macOS app (SwiftUI) for backing up Apple Photos to local folders (organized by date) or to Immich photo servers. It supports incremental/full/mirror backup modes, pause/resume, scheduled backups, and menu bar integration. Auto-updates via Sparkle.

## Build Commands

**Open in Xcode:**
```bash
open ImmiBridge/ImmiBridge.xcodeproj
```

**Build from command line:**
```bash
./scripts/build_ui_app_bundle.sh
# Output: build/ImmiBridge.app
```

**Build with xcodebuild directly:**
```bash
xcodebuild -project ImmiBridge/ImmiBridge.xcodeproj -scheme ImmiBridge -configuration Release build
```

**Create signed/notarized release DMG** (requires `.env` with signing credentials, see `.env.example`):
```bash
./scripts/release.sh
```

**Generate Sparkle appcast:**
```bash
./scripts/generate_appcast.sh
```

There are no linters or automated test suites in active use. Testing is manual — run the app and exercise backup workflows.

## Architecture

**Pattern:** MVVM with SwiftUI. Views observe `PhotoBackupViewModel` via `@EnvironmentObject`.

**Two modules under `ImmiBridge/ImmiBridge/`:**

### Core/ — Business logic (no UI dependencies)
- **PhotoBackupCore.swift** — Main export engine. Uses PhotoKit to enumerate and export assets. Handles iCloud downloads, metadata extraction, Immich uploads (with SHA1 dedup), and all three backup modes. Reports progress via `@escaping (PhotoBackupProgress) -> Void` closures. This is the largest file (~3,600 lines).
- **FileBackupCore.swift** — Backs up from folder sources (non-Photos).
- **FileImmichSync.swift** — Syncs local files to Immich server.
- **ManifestStore.swift** — SQLite (C API, WAL mode) database tracking which assets have been backed up, enabling incremental mode.
- **AssetMappingStore.swift** — SQLite database mapping PHAsset localIdentifiers to Immich asset IDs for metadata-only sync.
- **BackupTypes.swift** — `BackupMode`, `BackupSource`, `BackupProfile`, and other shared types.

### UI/ — SwiftUI views and state management
- **PhotoBackupViewModel.swift** (~1,700 lines) — Central state manager (`@MainActor`, `ObservableObject`). Manages configuration, backup execution orchestration, Photos library access, Immich connection testing.
- **ContentView.swift** — Tab-based primary interface (destination, source, options, history/logs).
- **BackupScheduler.swift** — Timer-based scheduled backup triggering with post-wake catchup.
- **AppDelegate.swift** — NSStatusItem (menu bar), Sparkle updater controller, window lifecycle, system wake notifications.
- **PhotoBackupApp.swift** — SwiftUI `@main` entry point. Shows SetupWizardView on first launch, then ContentView.

### Key data flow
1. User configures backup in ContentView tabs → settings stored in PhotoBackupViewModel `@Published` properties
2. Backup triggered (manual or BackupScheduler) → ViewModel calls PhotoBackupCore/FileBackupCore
3. Core reports progress via closures → ViewModel updates UI state
4. ManifestStore/AssetMappingStore persist incremental state in SQLite

## Dependencies

- **Sparkle 2.6.4** (via SPM) — auto-updates with EdDSA signing
- System frameworks: Photos (PhotoKit), CryptoKit, SQLite3, SwiftUI, AppKit, UserNotifications

## Key Configuration

- **Bundle ID:** `com.emerysilb.immibridge`
- **Min macOS:** 12.0
- **Entitlements:** App Sandbox, Photos library access, network client, user-selected file read-write
- **Info.plist** contains Sparkle feed URL and public key configuration

## Release Process

1. Update version in `.env`
2. Run `./scripts/release.sh` (builds universal binary, signs, notarizes, creates DMG)
3. Upload DMG to GitHub release: `gh release create v{VERSION} build/ImmiBridge-{VERSION}.dmg`
4. CI (`.github/workflows/appcast.yml`) auto-generates appcast.xml on push to main
