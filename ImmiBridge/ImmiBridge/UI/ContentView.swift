import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: PhotoBackupViewModel
    @EnvironmentObject private var scheduler: BackupScheduler
    @State private var immichAutoTestTask: Task<Void, Never>?
    @State private var isLogDrawerOpen: Bool = false
    @State private var showErrorsSheet: Bool = false
    @State private var showResetConfirm: Bool = false
    @State private var wipeManifestOnReset: Bool = true

    var body: some View {
        ZStack(alignment: .bottom) {
            DashboardBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    HStack(alignment: .top, spacing: 26) {
                        sourcesCard
                        destinationsCard
                    }

                    HStack(alignment: .top, spacing: 26) {
                        ScheduleSettingsView()
                        NotificationSettingsView()
                    }

                    Spacer(minLength: 0)
                }
                .padding(28)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    runBackupNowButton
                        .frame(width: 420)
                        .frame(maxWidth: .infinity)

                    progressStrip
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 18)
                .background {
                    Rectangle()
                        .fill(.thinMaterial)
                        .overlay(alignment: .top) {
                            Divider()
                                .overlay(DesignSystem.Colors.separator.opacity(0.7))
                        }
                        .ignoresSafeArea(edges: .bottom)
                }
            }

            topTitleBar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .zIndex(10)

            CollapsibleBottomDrawer(isOpen: $isLogDrawerOpen, height: 300) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Spacer()
                        Toggle("Wipe manifest DB", isOn: $wipeManifestOnReset)
                            .toggleStyle(.switch)
                            .disabled(model.isRunning)
                            .help("Deletes the destination manifest database so the next run behaves like a full re-export (for folder backups).")
                        Button("Reset…") {
                            showResetConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(model.isRunning)
                        HStack(spacing: 8) {
                            Text("Timeout (sec)")
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            TextField("", value: $model.timeoutSeconds, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                        }
                        .help("Maximum time in seconds to wait for each photo/file download from iCloud before timing out and moving to the next item. Can be changed while a backup is running.")
                    }

                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Log")
                                .font(.system(.headline, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            LogConsoleView(lines: model.logLines, isActive: isLogDrawerOpen)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Preview")
                                .font(.system(.headline, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            previewPanel
                        }
                        .frame(width: 280)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            .onChange(of: isLogDrawerOpen) { isOpen in
                model.setLogVisible(isOpen)
            }
            .alert("Reset and start fresh?", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    model.resetAndStartFresh(wipeManifestDatabase: wipeManifestOnReset)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(wipeManifestOnReset
                     ? "This clears local resume state, temp files, and deletes the destination manifest database (if a folder destination is set)."
                     : "This clears local resume state and temp files. The destination manifest database will be kept.")
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 750)
        .onAppear {
            model.refreshPhotosAuthorizationStatus()
            model.checkForResumableSession()
            model.setLogVisible(isLogDrawerOpen)
            scheduleImmichAutoTest()
            scheduler.bind(to: model)
        }
        .onChange(of: model.destinationMode) { newMode in
            if newMode == .immich || newMode == .both {
                scheduleImmichAutoTest()
            }
        }
        .onChange(of: model.immichApiKey) { _ in
            scheduleImmichAutoTest()
        }
        .onChange(of: model.immichServerURL) { _ in
            scheduleImmichAutoTest()
        }
        .alert("Immich Connection Failed", isPresented: $model.showImmichConnectionError) {
            if model.showLocalNetworkPermissionNeeded {
                Button("Open System Settings") {
                    model.openLocalNetworkSettings()
                }
                Button("Try Again") {
                    model.testImmich()
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(model.immichConnectionErrorMessage)
        }
        .sheet(isPresented: $model.showAlbumPicker) {
            AlbumPickerView()
                .environmentObject(model)
        }
    }
}

private extension ContentView {
    var topTitleBar: some View {
        ZStack {
            Rectangle()
                .fill(.thinMaterial)
                .allowsHitTesting(false)

            // Drag region (skip traffic lights area so window controls remain clickable).
            WindowDragHandle()
                .padding(.leading, 74)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("ImmiBridge")
                .font(.system(.headline, design: .rounded).bold())
                .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 96) // Keep clear of traffic lights and right edge
                .offset(y: -2) // Align visually with traffic lights
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(DesignSystem.Colors.separator.opacity(0.7))
        }
        .frame(height: 44)
        .ignoresSafeArea(edges: .top)
    }

    var sourcesCard: some View {
        let badge: StatusBadge = {
            switch model.sourceMode {
            case .photos:
                return StatusBadge(kind: model.photosIsConnected ? .success : .warning, text: model.photosConnectionText)
            case .files:
                return model.customFolderPaths.isEmpty
                    ? StatusBadge(kind: .muted, text: "No Folders")
                    : StatusBadge(kind: .success, text: "\(model.customFolderPaths.count) folder(s)")
            case .both:
                if !model.photosIsConnected {
                    return StatusBadge(kind: .warning, text: model.photosConnectionText)
                }
                return model.customFolderPaths.isEmpty
                    ? StatusBadge(kind: .info, text: "Photos Only")
                    : StatusBadge(kind: .success, text: "Ready")
            }
        }()

        let showPhotos = model.sourceMode == .photos || model.sourceMode == .both
        let showFiles = model.sourceMode == .files || model.sourceMode == .both

        return BackupCardView(
            title: "Sources: Photos & Files",
            badge: badge,
            leadingIcon: AnyView(IconPlate(systemName: "photo.on.rectangle.angled")),
            isDisabled: false
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Sources", selection: $model.sourceMode) {
                    Text("Photos").tag(PhotoBackupViewModel.SourceMode.photos)
                    Text("Files").tag(PhotoBackupViewModel.SourceMode.files)
                    Text("Both").tag(PhotoBackupViewModel.SourceMode.both)
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .disabled(model.isRunning)

                if showPhotos {
                    photosSection
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .move(edge: .top))
                        ))
                }

                if showPhotos && showFiles {
                    Divider()
                        .overlay(DesignSystem.Colors.separator)
                        .transition(.opacity)
                }

                if showFiles {
                    filesSection
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity.combined(with: .move(edge: .bottom))
                        ))
                }

                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: 0.25), value: model.sourceMode)
        }
    }

    var photosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                systemName: "photo.fill",
                title: "macOS Photos Library",
                trailing: AnyView(
                    HStack(spacing: 10) {
                        if model.photosConnectionText == "Permission Needed" {
                            Button("Grant Access") {
                                model.requestPhotosAccess()
                            }
                            .disabled(model.isRunning)
                        } else if model.photosConnectionText == "No Access" {
                            Button("Open Settings") {
                                model.openPhotosPrivacySettings()
                            }
                            .disabled(model.isRunning)
                        }

                        Button {
                            model.refreshPhotosAuthorizationStatus()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(.title3, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh Photos permission status.")
                    }
                )
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Mode:")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 70, alignment: .leading)
                    Picker("", selection: $model.mode) {
                        Text("Originals").tag(PhotoBackupViewModel.Mode.originals)
                        Text("Edited").tag(PhotoBackupViewModel.Mode.edited)
                        Text("Both").tag(PhotoBackupViewModel.Mode.both)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning)
                }

                HStack(spacing: 12) {
                    Text("Media:")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 70, alignment: .leading)
                    Picker("", selection: $model.media) {
                        Text("All").tag(PhotoBackupViewModel.Media.all)
                        Text("Images").tag(PhotoBackupViewModel.Media.images)
                        Text("Videos").tag(PhotoBackupViewModel.Media.videos)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning)
                }

                HStack(spacing: 12) {
                    Text("Order:")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 70, alignment: .leading)
                    Picker("", selection: $model.order) {
                        Text("Oldest").tag(PhotoBackupViewModel.Order.oldest)
                        Text("Newest").tag(PhotoBackupViewModel.Order.newest)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning)
                }

                HStack(spacing: 12) {
                    Text("Albums:")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 70, alignment: .leading)
                    Picker("", selection: $model.albumSource) {
                        Text("All Photos").tag(PhotoBackupViewModel.AlbumSource.allPhotos)
                        Text("Selected").tag(PhotoBackupViewModel.AlbumSource.selectedAlbums)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning)
                }

                if model.albumSource == .selectedAlbums {
                    HStack(spacing: 12) {
                        Text("")
                            .frame(width: 70, alignment: .leading)
                        HStack(spacing: 10) {
                            Button("Choose…") {
                                model.showAlbumPicker = true
                            }
                            .disabled(model.isRunning || !model.photosIsConnected)

                            Text("\(model.selectedAlbumIds.count) selected")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textSecondary)

                            Spacer()

                            Button("Refresh") {
                                model.refreshAlbumsIfPossible()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .disabled(model.isRunning || !model.photosIsConnected)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Text("Backup:")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 70, alignment: .leading)
                    Picker("", selection: $model.backupMode) {
                        Text("Smart").tag(PhotoBackupViewModel.BackupModeUI.smartIncremental)
                        Text("Full").tag(PhotoBackupViewModel.BackupModeUI.full)
                        Text("Mirror").tag(PhotoBackupViewModel.BackupModeUI.mirror)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning)
                    .help(backupModeHelpText(model.backupMode))
                }

                HStack(spacing: 12) {
                    Text("Library:")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 70, alignment: .leading)
                    Picker("", selection: $model.libraryScope) {
                        Text("Personal").tag(PhotoBackupViewModel.LibraryScope.personalOnly)
                        Text("Both").tag(PhotoBackupViewModel.LibraryScope.personalAndShared)
                        Text("Shared").tag(PhotoBackupViewModel.LibraryScope.sharedOnly)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning || model.albumSource == .selectedAlbums)
                    .help("Applies when Albums is set to All Photos. 'Shared' uses shared albums only; 'Both' includes personal library + shared albums.")
                }

                Toggle("Include Adjustment Data", isOn: $model.includeAdjustmentData)
                    .disabled(model.isRunning)

                Toggle("Include Hidden Photos", isOn: $model.includeHiddenPhotos)
                    .disabled(model.isRunning)

                Picker("Filename Format", selection: $model.filenameFormat) {
                    Text("Date + ID (default)").tag(FilenameFormat.dateAndId)
                    Text("Date + Original Name").tag(FilenameFormat.dateAndOriginal)
                    Text("Original Name Only").tag(FilenameFormat.originalOnly)
                }
                .disabled(model.isRunning)
                Text("Controls how exported files are named. 'Date + ID' uses capture date and asset ID. 'Date + Original Name' uses capture date and the original Photos filename. 'Original Name Only' uses just the original filename.")
                    .font(.caption)
                    .foregroundColor(.secondary)

            }
            .padding(14)
            .background(Color.black.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
        }
    }

    var filesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                systemName: "folder.fill",
                title: "Files (iCloud Drive / Custom)",
                trailing: AnyView(
                    HStack(spacing: 10) {
                        Button("Add…") { model.addCustomFolders() }
                            .disabled(model.isRunning)
                        Button("Clear") { model.clearCustomFolders() }
                            .disabled(model.isRunning || model.customFolderPaths.isEmpty)
                    }
                )
            )

            VStack(alignment: .leading, spacing: 10) {
                if model.customFolderPaths.isEmpty {
                    Text("No folders selected.")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                } else {
                    ForEach(Array(model.customFolderPaths.enumerated()), id: \.offset) { idx, path in
                        HStack(spacing: 10) {
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.92))
                            Spacer()
                            Button {
                                model.removeCustomFolder(at: idx)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isRunning)
                        }
                    }
                }
            }
            .padding(14)
            .background(Color.black.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
        }
    }

    var destinationsCard: some View {
        let badge: StatusBadge = {
            switch model.destinationMode {
            case .folder:
                return model.destinationPath.isEmpty
                    ? StatusBadge(kind: .muted, text: "Choose Folder")
                    : StatusBadge(kind: .success, text: "Ready")
            case .immich:
                if model.immichServerURL.isEmpty || model.immichApiKey.isEmpty {
                    return StatusBadge(kind: .muted, text: "Needs Setup")
                }
                return model.immichIsConnected ? StatusBadge(kind: .success, text: "Connected") : StatusBadge(kind: .info, text: model.immichTestStatus)
            case .both:
                if !model.canStartBoth {
                    return StatusBadge(kind: .muted, text: "Needs Setup")
                }
                return model.immichIsConnected ? StatusBadge(kind: .success, text: "Ready") : StatusBadge(kind: .info, text: model.immichTestStatus)
            }
        }()

        let showFolder = model.destinationMode == .folder || model.destinationMode == .both
        let showImmich = model.destinationMode == .immich || model.destinationMode == .both

        return BackupCardView(
            title: "Destinations: Folder & Immich",
            badge: badge,
            leadingIcon: AnyView(IconPlate(systemName: "externaldrive.fill")),
            isDisabled: false
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Destinations", selection: $model.destinationMode) {
                    Text("Folder").tag(PhotoBackupViewModel.DestinationMode.folder)
                    Text("Immich").tag(PhotoBackupViewModel.DestinationMode.immich)
                    Text("Both").tag(PhotoBackupViewModel.DestinationMode.both)
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .disabled(model.isRunning)

                if showFolder {
                    folderSection
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .move(edge: .top))
                        ))
                }

                if showFolder && showImmich {
                    Divider()
                        .overlay(DesignSystem.Colors.separator)
                        .transition(.opacity)
                }

                if showImmich {
                    immichSection
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity.combined(with: .move(edge: .bottom))
                        ))
                }

                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: 0.25), value: model.destinationMode)
        }
    }

    var folderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(systemName: "folder.fill", title: "Folder")

            VStack(alignment: .leading, spacing: 10) {
                Text("Path")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                HStack(spacing: 12) {
                    Text(model.destinationPath.isEmpty ? "Not set" : model.destinationPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Change…") {
                        model.chooseDestination()
                    }
                    .disabled(model.isRunning)
                }
            }
            .padding(14)
            .background(Color.black.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
        }
    }

    var immichSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(systemName: "network", title: "Immich Server")

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("Server URL")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 84, alignment: .leading)
                    TextField("http://host:2283", text: Binding(
                        get: { model.immichServerURL },
                        set: { model.setImmichServerURL($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isRunning)
                }

                HStack(spacing: 12) {
                    Text("API Key")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 84, alignment: .leading)
                    SecureField("x-api-key", text: $model.immichApiKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isRunning)
                    if model.immichApiKey.isEmpty && !model.immichServerURL.isEmpty {
                        Button("Get Key") {
                            model.openImmichApiKeysPage()
                        }
                        .disabled(model.isRunning)
                    }
                }

                HStack {
                    Spacer()
                    Button("Test Connection") {
                        model.testImmich()
                    }
                    .disabled(model.isRunning || model.immichServerURL.isEmpty || model.immichApiKey.isEmpty)
                }

                Divider()
                    .overlay(DesignSystem.Colors.separator.opacity(0.6))

                Toggle("Sync Photos albums to Immich albums", isOn: $model.immichSyncAlbums)
                    .toggleStyle(.switch)
                    .disabled(model.isRunning)

                Toggle("Replace assets in Immich when edited/changed", isOn: $model.immichUpdateChangedAssets)
                    .toggleStyle(.switch)
                    .disabled(model.isRunning)

                Toggle("Overwrite existing metadata in Immich", isOn: $model.immichMetadataOverwrite)
                    .toggleStyle(.switch)
                    .disabled(model.isRunning)
                    .help("When OFF (default): only add missing metadata (location, favorites). When ON: overwrite all metadata with Apple Photos values.")

                Divider()
                    .overlay(DesignSystem.Colors.separator.opacity(0.6))

                HStack(spacing: 12) {
                    Text("Parallel Uploads")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Stepper(value: $model.immichUploadConcurrency, in: 1...16) {
                        Text("\(model.immichUploadConcurrency)")
                            .monospacedDigit()
                            .frame(width: 24)
                    }
                    .disabled(model.isRunning)
                }
                .help("Number of simultaneous uploads to Immich. Photos from iCloud Photos must be fetched one at a time before upload, so higher values mainly help with local Photos libraries.")

            }
            .padding(14)
            .background(Color.black.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
        }
    }

    var previewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let img = model.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    }
                Text(model.thumbnailCaption)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                        }
                    Text("No preview yet")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .frame(width: 280, height: 180)
            }
        }
    }

    var runBackupNowButton: some View {
        VStack(spacing: 12) {
            // Session info banner when resumable session exists
            if model.hasResumableSession && !model.isRunning {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(DesignSystem.Colors.accentPrimary)
                    Text(model.resumableSessionInfo)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(DesignSystem.Colors.accentPrimary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // Button state machine
            HStack(spacing: 12) {
                if model.isRunning {
                    if model.isPaused {
                        // Paused mid-session: Resume + Stop
                        Button {
                            model.resume()
                        } label: {
                            Text("Resume")
                        }
                        .buttonStyle(PrimaryButtonStyle(isDestructive: false, height: 56))

                        Button {
                            model.cancel()
                        } label: {
                            Text("Stop")
                        }
                        .buttonStyle(SecondaryButtonStyle(isDestructive: true, height: 56))
                    } else {
                        // Running: Stop (resumable)
                        Button {
                            model.cancel()
                        } label: {
                            Text("Stop")
                        }
                        .buttonStyle(SecondaryButtonStyle(isDestructive: true, height: 56))
                        .help("Stops after the current item and saves state so you can resume later.")
                    }
                } else if model.hasResumableSession {
                    // Not running but has saved session: Resume + Start Fresh + Sync Metadata
                    Button {
                        model.resume()
                    } label: {
                        Text("Resume Backup")
                    }
                    .buttonStyle(PrimaryButtonStyle(isDestructive: false, height: 56))

                    Button {
                        model.clearSessionState()
                        model.start()
                    } label: {
                        Text("Start Fresh")
                    }
                    .buttonStyle(SecondaryButtonStyle(isDestructive: false, height: 56))
                    .disabled(!model.canStart)

                    Button {
                        model.startMetadataSync()
                    } label: {
                        Text("Sync Metadata")
                    }
                    .buttonStyle(SecondaryButtonStyle(isDestructive: false, height: 56))
                    .disabled(!model.canStart || model.destinationMode == .folder)
                    .help("Sync location, favorites, and other metadata for photos already in Immich (no upload).")
                } else {
                    // Normal start state
                    Button {
                        model.startMetadataSync()
                    } label: {
                        Text("Sync Metadata")
                    }
                    .buttonStyle(SecondaryButtonStyle(isDestructive: false, height: 56))
                    .disabled(!model.canStart || model.destinationMode == .folder)
                    .help("Sync location, favorites, and other metadata for photos already in Immich (no upload).")

                    Button {
                        model.startDryRun()
                    } label: {
                        Text("Dry Run")
                    }
                    .buttonStyle(SecondaryButtonStyle(isDestructive: false, height: 56))
                    .disabled(!model.canStart)
                    .help("Plan-only: checks Immich for existing device asset IDs; does not export or upload.")

                    Button {
                        model.start()
                    } label: {
                        Text("Run Backup Now")
                    }
                    .buttonStyle(PrimaryButtonStyle(isDestructive: false, height: 56))
                    .disabled(!model.canStart)
                }
            }
        }
    }

    var progressStrip: some View {
        let total = Int(model.progressTotal)
        let current = Int(model.progressValue)
        let percent: Double = (model.progressTotal > 0) ? (model.progressValue / model.progressTotal) : 0
        let immichHasExistProgress = model.isRunning && model.immichSyncInProgress && model.immichExistTotal > 0
        let immichPercent: Double = model.immichExistTotal > 0 ? (Double(model.immichExistChecked) / Double(model.immichExistTotal)) : 0

        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if model.isPaused {
                        // Paused indicator
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(Color.orange)
                        Text(total > 0 ? String(format: "Backup Paused %.1f%% (%d/%d items)", percent * 100, current, total) : "Backup Paused")
                            .font(.system(.headline, design: .rounded).bold())
                            .foregroundStyle(Color.orange)
                    } else {
                        Text(model.isRunning && total > 0 ? String(format: "Backup Running %.1f%% (%d/%d items)", percent * 100, current, total) : "PhotoBackupUtility")
                            .font(.system(.headline, design: .rounded).bold())
                            .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.92))
                    }
                }

                ProgressView(value: model.progressTotal > 0 ? percent : 0)
                    .progressViewStyle(.linear)
                    .tint(model.isPaused ? Color.orange : DesignSystem.Colors.accentPrimary)

                if immichHasExistProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: "Syncing with Immich %.1f%% (%d/%d)", immichPercent * 100, model.immichExistChecked, model.immichExistTotal))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                        ProgressView(value: immichPercent)
                            .progressViewStyle(.linear)
                            .tint(DesignSystem.Colors.textSecondary.opacity(0.7))
                    }
                }

                // iCloud download progress row
                if model.isDownloadingFromiCloud {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "icloud.and.arrow.down")
                                .foregroundStyle(DesignSystem.Colors.accentPrimary)
                            Text("Downloading from iCloud: \(model.iCloudDownloadAssetName)")
                            if model.iCloudDownloadAttempt > 1 {
                                Text("(retry #\(model.iCloudDownloadAttempt))")
                                    .foregroundStyle(DesignSystem.Colors.textSecondary.opacity(0.7))
                            }
                            Spacer()
                            Text("\(Int(model.iCloudDownloadProgress * 100))%")
                            Text("timeout: \(Int(model.timeoutSeconds))s")
                                .foregroundStyle(DesignSystem.Colors.textSecondary.opacity(0.6))
                            if let remaining = model.iCloudTimeoutRemaining, remaining < model.timeoutSeconds * 0.5 {
                                Text("(\(Int(remaining))s left)")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        ProgressView(value: model.iCloudDownloadProgress)
                            .progressViewStyle(.linear)
                            .tint(DesignSystem.Colors.accentPrimary.opacity(0.7))
                    }
                }

                Text(model.isRunning ? model.statusText : "Idle")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .overlay(DesignSystem.Colors.separator)
                .frame(height: 64)

            HStack(spacing: 12) {
                Group {
                    if let img = model.thumbnail {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }

                HStack(spacing: 16) {
                    VStack(spacing: 2) {
                        Text("\(model.uploadedCount)")
                            .font(.system(.title2, design: .rounded).bold())
                            .foregroundStyle(DesignSystem.Colors.accentPrimary)
                        Text("Uploaded")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    VStack(spacing: 2) {
                        Text("\(model.skippedCount)")
                            .font(.system(.title2, design: .rounded).bold())
                            .foregroundStyle(Color.orange)
                        Text("Skipped")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    VStack(spacing: 2) {
                        Button {
                            showErrorsSheet = true
                        } label: {
                            VStack(spacing: 2) {
                                Text("\(model.errorCount)")
                                    .font(.system(.title2, design: .rounded).bold())
                                    .foregroundStyle(model.errorCount > 0 ? Color.red : DesignSystem.Colors.textSecondary)
                                Text("Errors")
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("View errors and failed uploads")
                    }
                }
                .frame(width: 200, alignment: .center)

                HStack(spacing: 10) {
                    Button {
                        isLogDrawerOpen.toggle()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(.title3, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.85))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(isLogDrawerOpen ? "Hide logs" : "Show logs")
                }
            }
        }
        .padding(18)
        .cardBackground()
        .frame(height: 110)
        .sheet(isPresented: $showErrorsSheet) {
            ErrorsSheetView()
                .environmentObject(model)
        }
    }

    func scheduleImmichAutoTest() {
        immichAutoTestTask?.cancel()
        guard !model.isRunning else { return }
        guard !model.immichServerURL.isEmpty, !model.immichApiKey.isEmpty else { return }

        immichAutoTestTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                model.maybeAutoTestImmich()
            }
        }
    }
}

private func backupModeHelpText(_ mode: PhotoBackupViewModel.BackupModeUI) -> String {
    switch mode {
    case .smartIncremental:
        return "Smart Incremental: only exports items that are new or changed since the last run (tracked via a manifest in the destination)."
    case .full:
        return "Full: re-exports everything every run (no manifest-based skipping)."
    case .mirror:
        return "Mirror: like Smart Incremental, but also deletes files from the backup destination when the source no longer contains them. Never deletes from Photos/iCloud."
    }
}

private struct ErrorsSheetView: View {
    @EnvironmentObject private var model: PhotoBackupViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Errors")
                    .font(.system(.title2, design: .rounded).bold())
                Spacer()
                Button("Copy") {
                    model.copyErrorsToClipboard()
                }
                Button("Open Failed Uploads Log") {
                    model.openFailedUploadsFolder()
                }
                .disabled(model.failedUploadCount == 0)
                Button(model.isExportingFailedUploads ? "Exporting…" : "Export Failed Assets…") {
                    model.exportFailedUploadsToFolder()
                }
                .disabled(model.isRunning || model.isExportingFailedUploads || model.failedUploadCount == 0)
                Button("Close") { dismiss() }
            }

            Text("\(model.failedUploadCount) failed upload(s) recorded (no files saved)")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            if model.errorLines.isEmpty {
                Text("No errors captured yet.")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List(model.errorLines) { line in
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 520)
    }
}
