# Contributing to ImmiBridge

Thank you for your interest in contributing to ImmiBridge! This document provides guidelines and instructions for contributing.

## Development Setup

### Requirements

- macOS 13.0 or later
- Xcode 15.0 or later
- Apple Developer account (free account works for local development)

### Getting Started

1. **Fork and clone the repository**

   ```bash
   git clone https://github.com/YOUR_USERNAME/ImmiBridge.git
   cd ImmiBridge
   ```

2. **Open in Xcode**

   ```bash
   open ImmiBridge/ImmiBridge.xcodeproj
   ```

3. **Configure code signing**

   - Select the `ImmiBridge` project in the navigator
   - Select the `ImmiBridge` target
   - Go to **Signing & Capabilities**
   - Change **Team** to your Apple Developer team
   - Xcode will automatically manage signing

4. **Build and run**

   - Select the `ImmiBridge` scheme
   - Press ⌘R to build and run

### Project Structure

```
ImmiBridge/
├── ImmiBridge/
│   ├── ImmiBridge/
│   │   ├── Core/                  # Backup logic
│   │   │   ├── PhotoBackupCore.swift
│   │   │   ├── FileBackupCore.swift
│   │   │   ├── BackupTypes.swift
│   │   │   └── ...
│   │   ├── UI/                    # SwiftUI interface
│   │   │   ├── ContentView.swift
│   │   │   ├── PhotoBackupViewModel.swift
│   │   │   ├── MenuBarView.swift
│   │   │   └── ...
│   │   └── Assets.xcassets
│   └── ImmiBridge.xcodeproj
├── scripts/
│   ├── build_ui_app_bundle.sh     # Build via command line
│   └── release.sh                 # Create notarized release
├── assets/                        # App icons
├── LICENSE
├── README.md
└── CONTRIBUTING.md
```

### Building

**In Xcode:**
- Press ⌘B to build
- Press ⌘R to build and run

**Via command line:**
```bash
./scripts/build_ui_app_bundle.sh
```

The built app will be at `build/ImmiBridge.app`.

## Making Changes

### Code Style

- Follow Swift standard naming conventions
- Use meaningful variable and function names
- Keep functions focused and reasonably sized
- Add comments for complex logic

### Architecture Overview

**Core Module** (`Core/`):
- `PhotoBackupCore.swift` - Main export engine using PhotoKit
- `FileBackupCore.swift` - File/folder backup logic
- `BackupTypes.swift` - Shared data types
- `ManifestStore.swift` - Tracks completed backups for incremental mode

**UI Module** (`UI/`):
- `PhotoBackupViewModel.swift` - Main state management (MVVM)
- `ContentView.swift` - Primary interface
- `MenuBarView.swift` - Menu bar extra

**Patterns:**
- **MVVM**: Views observe `PhotoBackupViewModel` via `@EnvironmentObject`
- **Async/await**: Network and file operations use Swift concurrency
- **Progress callbacks**: Core module reports progress via closures

### Testing Your Changes

1. **Test common workflows:**
   - Configure a backup destination
   - Run a backup (use dry-run or limit for quick tests)
   - Test pause/resume functionality
   - Verify Immich connection (if applicable)

2. **Test permissions:**
   - Test on a fresh install if possible
   - Verify Photos and Local Network permission prompts appear correctly

### Submitting Changes

1. **Create a feature branch**

   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** and commit with clear messages

   ```bash
   git commit -m "Add feature: description of what you added"
   ```

3. **Push to your fork**

   ```bash
   git push origin feature/your-feature-name
   ```

4. **Open a Pull Request** with:
   - Clear description of the changes
   - Any relevant issue numbers
   - Screenshots for UI changes

## Creating a Release

To create a notarized release for distribution:

```bash
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="your@email.com"
export APPLE_TEAM_ID="TEAMID"
export APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export VERSION="1.0.0"

./scripts/release.sh
```

This creates a notarized DMG at `build/ImmiBridge-1.0.0.dmg`.

## Reporting Issues

When reporting bugs, please include:

- macOS version
- App version (or commit hash if building from source)
- Steps to reproduce
- Expected vs actual behavior
- Any error messages or logs

## Questions?

Feel free to open an issue for questions or discussion about potential changes.
