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

## Creating a Signed Release

To distribute ImmiBridge outside the App Store, the app must be signed with a Developer ID certificate and notarized by Apple. This prevents Gatekeeper warnings for users.

### Prerequisites

1. **Apple Developer Program membership** ($99/year) - [developer.apple.com/programs](https://developer.apple.com/programs)

2. **Developer ID Application certificate**
   - Go to [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)
   - Click **+** → Select **Developer ID Application**
   - Follow the prompts to create and download the certificate
   - Double-click to install in Keychain

3. **Verify your certificate is installed:**
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID"
   ```

4. **Create an app-specific password** for notarization:
   - Go to [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords
   - Generate a new password and save it

### Configuration

Copy the example environment file and fill in your values:

```bash
cp .env.example .env
```

Edit `.env` with your credentials:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
APPLE_ID="your@email.com"
APPLE_TEAM_ID="XXXXXXXXXX"
APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
VERSION="1.0.0"
```

> **Note:** `.env` is git-ignored and will not be committed.

### Building the Release

```bash
./scripts/release.sh
```

This will:
1. Build the app in Release configuration
2. Sign it with your Developer ID certificate
3. Submit to Apple for notarization (takes 1-5 minutes)
4. Staple the notarization ticket to the app
5. Create a signed DMG at `build/ImmiBridge-{VERSION}.dmg`

### Uploading to GitHub

```bash
gh release create v1.0.0 build/ImmiBridge-1.0.0.dmg --title "v1.0.0" --generate-notes
```

## Reporting Issues

When reporting bugs, please include:

- macOS version
- App version (or commit hash if building from source)
- Steps to reproduce
- Expected vs actual behavior
- Any error messages or logs

## Questions?

Feel free to open an issue for questions or discussion about potential changes.
